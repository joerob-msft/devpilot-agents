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
internal sealed class ChildToolInvoker(CoordinatorRequest request)
{
    internal const string ResultContractVersion = "devpilot.shadow-run-coordinator.child-result.v1";
    internal const string JournalContractVersion = "devpilot.shadow-run-coordinator.child-journal.v1";

    private readonly CoordinatorRequest _request = request;
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
        CanonicalJson.WriteFileAtomic(requestPath, CanonicalJson.Readable(childRequest));

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
                return adopted;
            }
            // A result that cannot be adopted would let a child that never ran
            // look like one that succeeded.
            File.Delete(resultPath);
        }

        // Intent is journalled BEFORE the process starts, so a coordinator killed
        // during a child leaves behind the evidence that a child was in flight.
        // Written even on a first attempt, because the interesting reader is the
        // resume that has to explain a missing result.
        var attempt = ReadJournalAttempt(journalPath, step, childRequestSha256) + 1;
        CanonicalJson.WriteFileAtomic(journalPath, CanonicalJson.Readable(new MapNode()
            .Set("contractVersion", JournalContractVersion)
            .Set("correlationId", _request.CorrelationId)
            .Set("step", step)
            .Set("childRequestSha256", childRequestSha256)
            .Set("attempt", attempt)
            .Set("launchedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture))));

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

        _childInFlight = true;
        LaunchCount++;
        var standardOut = new StringBuilder();
        var standardError = new StringBuilder();
        Process? process = null;
        try
        {
            process = Process.Start(start) ?? throw new ChildFailureException($"The '{step}' child did not start.");
            process.OutputDataReceived += (_, args) => { if (args.Data is not null) { standardOut.AppendLine(args.Data); } };
            process.ErrorDataReceived += (_, args) => { if (args.Data is not null) { standardError.AppendLine(args.Data); } };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.StandardInput.Close();

            var budget = TimeSpan.FromSeconds(_request.ChildTimeoutSeconds);
            if (!process.WaitForExit((int)budget.TotalMilliseconds))
            {
                KillTree(process);
                // The same drain the success path takes. Reading the builders while
                // the asynchronous readers can still be appending to them is a data
                // race on a type that is not thread safe, and it would turn a
                // timed-out child into an unhandled crash with an undocumented exit
                // code rather than into the child failure it is.
                process.WaitForExit();
                WriteLogs(outLog, errorLog, standardOut, standardError);
                throw new ChildFailureException(
                    $"The '{step}' child exceeded its {_request.ChildTimeoutSeconds.ToString(CultureInfo.InvariantCulture)} second budget and was killed with its process tree.");
            }
            // Lets the asynchronous readers drain; without it the logs can lose
            // the last lines the child wrote before exiting.
            process.WaitForExit();
            WriteLogs(outLog, errorLog, standardOut, standardError);

            if (process.ExitCode != 0)
            {
                throw new ChildFailureException(
                    $"The '{step}' child exited {process.ExitCode.ToString(CultureInfo.InvariantCulture)}; see '{errorLog}'.");
            }
        }
        finally
        {
            _childInFlight = false;
            if (process is not null)
            {
                // Belt and braces against an orphan: if anything above threw
                // between start and exit, the tree goes with it.
                if (!process.HasExited)
                {
                    KillTree(process);
                }
                process.Dispose();
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
    {
        var label = $"'{step}' child result";
        var result = StrictJson.ReadObjectFile(resultPath, label);
        StrictJson.RequireLiteral(result, "contractVersion", ResultContractVersion, label);
        StrictJson.RequireLiteral(result, "step", step, label);
        StrictJson.RequireLiteral(result, "correlationId", _request.CorrelationId, label);
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

    /// <summary>
    /// The attempt count already journalled for this exact step and child request,
    /// or zero when there is no usable journal entry.
    /// </summary>
    private int ReadJournalAttempt(string journalPath, string step, string childRequestSha256)
    {
        if (!File.Exists(journalPath))
        {
            return 0;
        }
        try
        {
            const string label = "child step journal";
            var root = StrictJson.ReadObjectFile(journalPath, label, maximumBytes: 64 * 1024);
            StrictJson.RequireLiteral(root, "contractVersion", JournalContractVersion, label);
            if (!string.Equals(StrictJson.RequireString(root, "step", label), step, StringComparison.Ordinal)
                || !string.Equals(StrictJson.RequireString(root, "correlationId", label), _request.CorrelationId, StringComparison.Ordinal)
                || !string.Equals(StrictJson.RequireString(root, "childRequestSha256", label), childRequestSha256, StringComparison.Ordinal))
            {
                return 0;
            }
            return StrictJson.RequireInt(root, "attempt", label, 1, int.MaxValue);
        }
        catch (ContractException)
        {
            // A journal is a diagnostic aid for a resume, never a gate. An
            // unreadable one must not be able to stop a run.
            return 0;
        }
    }

    private static void KillTree(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit(30_000);
        }
        catch (InvalidOperationException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
        catch (NotSupportedException)
        {
        }
    }

    private static void WriteLogs(string outLog, string errorLog, StringBuilder standardOut, StringBuilder standardError)
    {
        File.WriteAllText(outLog, standardOut.ToString(), StrictJson.StrictUtf8);
        File.WriteAllText(errorLog, standardError.ToString(), StrictJson.StrictUtf8);
    }
}
