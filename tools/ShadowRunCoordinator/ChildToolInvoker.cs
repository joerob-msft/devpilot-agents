using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

internal sealed class ChildFailureException(string message) : Exception(message);

internal sealed record ChildOutcome(int ExitCode, string ResultPath, JsonElement Result, string ResultSha256);

/// <summary>
/// The only way this coordinator starts a process.
/// </summary>
/// <remarks>
/// Four rules, each of which is a fault this design refuses to leave available.
///
/// One child at a time, synchronously. A control plane that can have two children
/// in flight has to reason about which one wrote a file, and this slice has no
/// need of that.
///
/// The contract is a file, never standard output. The child is told where to read
/// its request and where to write its result. Standard output and standard error
/// are captured to log files for a human and are never parsed: a diagnostic line
/// from a well-meaning helper cannot become part of a decision.
///
/// A bounded wait, and a kill that takes the whole tree. A child that hangs is
/// killed along with anything it started, so a timeout cannot leave an orphan
/// holding a file handle on the output root.
///
/// A result the child did not write is not a result. A missing, empty, truncated,
/// byte-order-marked or wrong-versioned result file fails the step even when the
/// child exited zero, because a zero exit from a partially written step is
/// exactly the fault a file contract exists to catch.
/// </remarks>
internal sealed class ChildToolInvoker(CoordinatorRequest request, LaunchLedger ledger)
{
    internal const string ResultContractVersion = "devpilot.shadow-run-coordinator.child-result.v1";

    /// <summary>How long a killed tree is given to go before the run stops waiting on it.</summary>
    internal const int DrainMilliseconds = 30_000;

    private readonly CoordinatorRequest _request = request;
    private readonly LaunchLedger _ledger = ledger;
    private bool _childInFlight;

    /// <summary>Children this process actually started, as opposed to results it adopted.</summary>
    internal int LaunchCount { get; private set; }

    /// <summary>Results adopted from a previous attempt that had already published them.</summary>
    internal int AdoptedCount { get; private set; }

    internal ChildOutcome Invoke(string step, string scriptPath, MapNode childRequest, params string[] expectedResultFields)
    {
        if (_childInFlight)
        {
            throw new ContractException("A second child was requested while one was still in flight; this coordinator runs one child at a time.");
        }

        Directory.CreateDirectory(_request.ExchangeRoot);
        Directory.CreateDirectory(_request.LogRoot);

        var stem = _request.CorrelationId + "-" + step;
        var requestPath = Path.Combine(_request.ExchangeRoot, stem + ".request.json");
        var resultPath = Path.Combine(_request.ExchangeRoot, stem + ".result.json");
        var journalPath = Path.Combine(_request.ExchangeRoot, stem + ".journal.json");
        var outLog = Path.Combine(_request.LogRoot, stem + ".out.log");
        var errorLog = Path.Combine(_request.LogRoot, stem + ".err.log");

        childRequest.Set("correlationId", _request.CorrelationId);
        childRequest.Set("step", step);
        childRequest.Set("resultPath", resultPath);
        // The identity of the WORK, not of the file: canonical bytes of the child
        // request as it stands before the digest itself is added. Two attempts at
        // the same step of the same coordinator request produce the same digest,
        // which is what makes adoption safe and makes a changed request refuse to
        // adopt. It is handed to the child so the child can echo it back rather
        // than reimplement canonicalisation in a second language.
        var childRequestSha256 = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(childRequest));
        childRequest.Set("childRequestSha256", childRequestSha256);

        // ---------------------------------------------------------------------
        // Adoption. This is the fix for the one window a control plane cannot
        // test its way out of: the child completes a durable, NON-REPEATABLE side
        // effect (a published snapshot, a declared run set), atomically publishes
        // its result, and the coordinator is killed before it can commit the
        // transition. Treating 'not committed' as 'not done' would re-run a child
        // that refuses to repeat itself, and the output root would be wedged
        // permanently: every later resume would take the identical path and fail
        // the identical way.
        //
        // A result is adopted only when it is a complete, strictly valid result
        // for THIS step of THIS correlation id AND it records the same child
        // request digest. Anything else is discarded rather than trusted.
        // ---------------------------------------------------------------------
        if (File.Exists(resultPath))
        {
            if (TryAdopt(step, resultPath, childRequestSha256, expectedResultFields, out var adopted))
            {
                AdoptedCount++;
                // The adopted result IS the account of the launch that produced
                // it, so the intent that launch opened stops being open. Without
                // this, the repair path that adoption exists to provide would
                // itself leave the root refusing every later run.
                _ledger.Close(step, "adopted", "a published result for this exact request was adopted");
                return adopted;
            }
        }

        // Asked here, after adoption and before ANY write. Adoption comes first
        // because it is the repair path - a published result accounts for the
        // launch that produced it - but everything below this line either
        // destroys evidence (the unadoptable result) or writes into an output
        // root that an unaccounted-for child may still own, and a run that is
        // about to refuse must do neither.
        _ledger.RequireLaunchable(step);

        if (File.Exists(resultPath))
        {
            // A result that cannot be adopted would let a child that never ran
            // look like one that succeeded.
            File.Delete(resultPath);
        }
        CanonicalJson.WriteFileAtomic(requestPath, CanonicalJson.Readable(childRequest));

        // Intent is journalled BEFORE the process starts, so a coordinator killed
        // during a child leaves behind the evidence that a child was in flight.
        // Written even on a first attempt, because the interesting reader is the
        // resume that has to explain a missing result.
        var attempt = ChildJournal.ReadAttempt(journalPath, _request.CorrelationId, step, childRequestSha256) + 1;
        ChildJournal.Write(journalPath, _request.CorrelationId, step, childRequestSha256, attempt, null);

        var start = new ProcessStartInfo
        {
            FileName = _request.PowerShellPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = StrictJson.StrictUtf8,
            StandardErrorEncoding = StrictJson.StrictUtf8,
            WorkingDirectory = _request.ToolkitRoot,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-File");
        start.ArgumentList.Add(scriptPath);
        start.ArgumentList.Add("-RequestPath");
        start.ArgumentList.Add(requestPath);

        // The signed intent goes down before the process exists, and it refuses
        // outright when a previous intent for this step was never accounted for.
        // The journal above says what is running; this says what was ever meant
        // to run, which is the only thing a coordinator killed inside
        // Process.Start leaves behind.
        var intent = _ledger.Open(step, childRequestSha256, start, requestPath, resultPath);

        _childInFlight = true;
        LaunchCount++;
        var standardOut = new StringBuilder();
        var standardError = new StringBuilder();
        Process? process = null;
        var closure = "faulted";
        var closureReason = "the step did not reach an outcome this coordinator recorded";
        try
        {
            try
            {
                process = Process.Start(start) ?? throw new ChildFailureException($"The '{step}' child did not start.");
            }
            catch (Exception error)
            {
                // A start that FAILED is the one case where the absence of a child
                // is provable rather than merely likely, so it is recorded as such:
                // the next run may launch this step again without wondering what
                // the last one left behind.
                _ledger.RecordNotStarted(intent, error.Message);
                throw;
            }
            // The child's exact identity goes into the journal the moment it
            // exists. A coordinator killed from outside cannot clean up after
            // itself, so this record is the only thing that can tell a later run
            // that a writer of this output root is still alive. PID alone would
            // not do: process ids are recycled.
            _ledger.RecordStart(intent, process);
            ChildJournal.Write(journalPath, _request.CorrelationId, step, childRequestSha256, attempt, process);
            process.OutputDataReceived += (_, args) => { if (args.Data is not null) { lock (standardOut) { standardOut.AppendLine(args.Data); } } };
            process.ErrorDataReceived += (_, args) => { if (args.Data is not null) { lock (standardError) { standardError.AppendLine(args.Data); } } };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.StandardInput.Close();

            var budget = TimeSpan.FromSeconds(_request.ChildTimeoutSeconds);
            if (!process.WaitForExit((int)budget.TotalMilliseconds))
            {
                ChildJournal.KillTree(process, DrainMilliseconds);
                // The same drain the success path takes. Reading the builders while
                // the asynchronous readers can still be appending to them is a data
                // race on a type that is not thread safe, and it would turn a
                // timed-out child into an unhandled crash with an undocumented exit
                // code rather than into the child failure it is.
                process.WaitForExit();
                WriteLogs(outLog, errorLog, standardOut, standardError);
                closure = "timeoutKilled";
                closureReason = $"the child exceeded its {_request.ChildTimeoutSeconds.ToString(CultureInfo.InvariantCulture)} second budget and its tree was killed";
                throw new ChildFailureException(
                    $"The '{step}' child exceeded its {_request.ChildTimeoutSeconds.ToString(CultureInfo.InvariantCulture)} second budget and was killed with its process tree.");
            }
            // Lets the asynchronous readers drain; without it the logs can lose
            // the last lines the child wrote before exiting.
            process.WaitForExit();
            WriteLogs(outLog, errorLog, standardOut, standardError);

            if (process.ExitCode != 0)
            {
                closure = "exitedNonZero";
                closureReason = $"the child exited {process.ExitCode.ToString(CultureInfo.InvariantCulture)}";
                throw new ChildFailureException(
                    $"The '{step}' child exited {process.ExitCode.ToString(CultureInfo.InvariantCulture)}; see '{errorLog}'.");
            }
            closure = "exited";
            closureReason = "the child exited zero";
        }
        finally
        {
            _childInFlight = false;
            // Whether the child is provably gone, which is not the same question
            // as whether the kill call returned. KillTree is best effort by
            // construction, so this is re-asked after the drain.
            var exited = true;
            if (process is not null)
            {
                // Belt and braces against an orphan: if anything above threw
                // between start and exit, the tree goes with it.
                if (!process.HasExited)
                {
                    ChildJournal.KillTree(process, DrainMilliseconds);
                }
                exited = process.HasExited;
                process.Dispose();
            }
            // The child is gone, so the journal must stop claiming a live writer.
            // Written last, and unconditionally: a stale liveness claim would
            // refuse every later run against this root.
            ChildJournal.TryClearChild(journalPath, _request.CorrelationId, step, childRequestSha256, attempt);
            // And the intent stops being open, whichever way the step ended. An
            // intent left open is read as an unknown launch, which refuses every
            // later run - so this must happen on the failure paths too. A child
            // this run could not prove had exited is recorded as abandoned rather
            // than closed, because 'closed' says the step may be attempted again
            // and that would be a second writer of one output root.
            if (exited)
            {
                _ledger.Close(step, closure, closureReason);
            }
            else
            {
                _ledger.Abandon(step, $"{closureReason}, and its tree could not be confirmed stopped");
            }
        }

        var label = $"'{step}' child result";
        // A malformed result is the CHILD's failure, not the caller's. Letting a
        // strict-reader refusal surface as a request-contract failure would tell
        // an operator to go and fix a request that is perfectly well formed.
        JsonElement result;
        try
        {
            result = ReadValidatedResult(step, resultPath, childRequestSha256, expectedResultFields);
        }
        catch (ContractException error)
        {
            throw new ChildFailureException(error.Message);
        }
        if (!StrictJson.RequireBool(result, "ok", label))
        {
            throw new ChildFailureException($"The '{step}' child reported failure in its result file.");
        }
        return new ChildOutcome(0, resultPath, result, CanonicalJson.Sha256HexOfFile(resultPath));
    }

    /// <summary>
    /// Reads a child result and refuses it unless it is a complete, strictly
    /// valid result for this step, this correlation id and this exact child
    /// request.
    /// </summary>
    private JsonElement ReadValidatedResult(string step, string resultPath, string childRequestSha256, string[] expectedResultFields)
        => ReadValidatedResult(step, _request.CorrelationId, resultPath, childRequestSha256, expectedResultFields);

    /// <summary>
    /// Reads a child result and refuses it unless it is a complete, strictly
    /// valid result for this step, this correlation id and this exact child
    /// request. Shared with the slot supervisor so that a supervised child's
    /// result is admitted on exactly the terms a short child's result is.
    /// </summary>
    internal static JsonElement ReadValidatedResult(
        string step,
        string correlationId,
        string resultPath,
        string childRequestSha256,
        string[] expectedResultFields)
    {
        var label = $"'{step}' child result";
        var result = StrictJson.ReadObjectFile(resultPath, label);
        StrictJson.RequireLiteral(result, "contractVersion", ResultContractVersion, label);
        StrictJson.RequireLiteral(result, "step", step, label);
        StrictJson.RequireLiteral(result, "correlationId", correlationId, label);
        // Binds the result to the work that was asked for. Without it a result
        // published for a different request could be adopted by this one purely
        // because it landed at the same path.
        StrictJson.RequireLiteral(result, "childRequestSha256", childRequestSha256, label);
        foreach (var field in expectedResultFields)
        {
            if (!result.TryGetProperty(field, out _))
            {
                throw new ContractException($"The '{step}' child result is missing required field '{field}'.");
            }
        }
        return result;
    }

    private bool TryAdopt(
        string step,
        string resultPath,
        string childRequestSha256,
        string[] expectedResultFields,
        out ChildOutcome outcome)
    {
        outcome = null!;
        JsonElement result;
        try
        {
            result = ReadValidatedResult(step, resultPath, childRequestSha256, expectedResultFields);
            // Only a SUCCESSFUL result is adoptable. A published failure is a
            // step that has to be attempted again, not a step that is done.
            if (!StrictJson.RequireBool(result, "ok", $"'{step}' child result"))
            {
                return false;
            }
        }
        catch (ContractException)
        {
            return false;
        }
        outcome = new ChildOutcome(0, resultPath, result, CanonicalJson.Sha256HexOfFile(resultPath));
        return true;
    }


    private static void WriteLogs(string outLog, string errorLog, StringBuilder standardOut, StringBuilder standardError)
    {
        lock (standardOut)
        {
            File.WriteAllText(outLog, standardOut.ToString(), StrictJson.StrictUtf8);
        }
        lock (standardError)
        {
            File.WriteAllText(errorLog, standardError.ToString(), StrictJson.StrictUtf8);
        }
    }
}
