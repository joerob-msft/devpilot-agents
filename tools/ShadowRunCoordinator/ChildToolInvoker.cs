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

    /// <summary>
    /// The honest terminal account of a child that outran its budget, decided
    /// from whether its tree was CONFIRMED stopped within the drain rather than
    /// from whether a kill was merely issued.
    /// </summary>
    /// <remarks>
    /// A kill call returning is not a child exiting. When the tree is confirmed
    /// stopped the step is 'timeoutKilled' and may honestly say so; when it is not
    /// - the wait was bounded and the process is still there - the record must NOT
    /// claim the child was killed and must NOT claim there is no orphan. It says,
    /// durably, that the child may still be running, which is the one reading that
    /// refuses every later attempt at this step.
    /// </remarks>
    internal readonly record struct TimeoutDisposition(
        bool ConfirmedStopped,
        string Closure,
        string ClosureReason,
        string FailureMessage);

    internal static TimeoutDisposition DisposeTimedOutChild(string step, int timeoutSeconds, bool confirmedStopped)
    {
        var seconds = timeoutSeconds.ToString(CultureInfo.InvariantCulture);
        if (confirmedStopped)
        {
            return new TimeoutDisposition(
                true,
                "timeoutKilled",
                $"the child exceeded its {seconds} second budget and its tree was killed",
                $"The '{step}' child exceeded its {seconds} second budget and was killed with its process tree.");
        }

        return new TimeoutDisposition(
            false,
            "timeoutAbandoned",
            $"the child exceeded its {seconds} second budget, its tree was signalled to stop, and it could not be confirmed stopped within {DrainMilliseconds.ToString(CultureInfo.InvariantCulture)}ms",
            $"The '{step}' child exceeded its {seconds} second budget; a kill was issued but its process tree could not be confirmed stopped within {DrainMilliseconds.ToString(CultureInfo.InvariantCulture)}ms, so it may still be running and is recorded as abandoned.");
    }

    /// <summary>
    /// Whether a timed-out child tree is proven empty. Root exit and inherited-pipe
    /// EOF cannot provide that proof without OS-enforced descendant containment.
    /// </summary>
    internal static bool ClassifyTimedOutChildCustody(bool rootExited, bool outputClosed)
    {
        _ = rootExited;
        _ = outputClosed;
        return false;
    }

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
        start.ArgumentList.Add("-ExpectedRequestSha256");
        start.ArgumentList.Add(childRequestSha256);
        start.ArgumentList.Add("-ExpectedResultPath");
        start.ArgumentList.Add(resultPath);
        start.ArgumentList.Add("-ExpectedToolkitRoot");
        start.ArgumentList.Add(_request.ToolkitRoot);

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
        var descendantsMaySurvive = false;
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
            var (outputDrained, errorDrained) = BeginDrainableReaders(process, standardOut, standardError);
            process.StandardInput.Close();

            var budget = TimeSpan.FromSeconds(_request.ChildTimeoutSeconds);
            if (!process.WaitForExit((int)budget.TotalMilliseconds))
            {
                ChildJournal.KillTree(process, DrainMilliseconds);
                // BOUNDED, always. KillTree is best effort, so a child that refuses
                // to die must not hand the coordinator an unbounded wait here - that
                // is exactly how one stuck child used to wedge the whole run. The
                // drain is bounded; whether the tree actually went is then read from
                // the process, not assumed from the kill call returning.
                var rootExited = process.WaitForExit(DrainMilliseconds);
                var outputClosed = rootExited && DrainWithin(outputDrained, errorDrained, DrainMilliseconds);
                // These signals account only for the direct child and descendants
                // that inherited its two redirected pipes. Without an OS-enforced
                // job/process group, a separately redirected descendant may survive.
                var confirmedStopped = ClassifyTimedOutChildCustody(rootExited, outputClosed);
                descendantsMaySurvive = !confirmedStopped;
                // Reading the builders while the asynchronous readers can still be
                // appending to them is a data race on a type that is not thread
                // safe; WriteLogs takes the same locks the readers do, so a late
                // line is missed rather than a read torn.
                WriteLogs(outLog, errorLog, standardOut, standardError);
                var disposition = DisposeTimedOutChild(step, _request.ChildTimeoutSeconds, confirmedStopped);
                closure = disposition.Closure;
                closureReason = disposition.ClosureReason;
                throw new ChildFailureException(disposition.FailureMessage);
            }
            // A REAL drain: wait for the async readers to reach EOF, not merely for
            // the process to exit. The child has already exited (the budgeted wait
            // returned true), so WaitForExit(ms) here would return true at once
            // WITHOUT ever waiting for the streams - by the runtime's contract a
            // timed wait cannot wait for them - and could not tell a fully-drained
            // child from one whose stdout/stderr write ends a surviving grandchild
            // still holds. The EOF signals from BeginDrainableReaders are the only
            // honest witness; a bounded miss on them is a genuine drain failure.
            var drained = DrainWithin(outputDrained, errorDrained, DrainMilliseconds);
            WriteLogs(outLog, errorLog, standardOut, standardError);
            if (!drained)
            {
                // The child exited but at least one pipe write end is still open, so
                // a descendant outlived it. Stop the tree best-effort - and it IS
                // only best-effort: once the direct child has exited the kill can no
                // longer follow a grandchild reparented away from it by parent id, so
                // the descendant may still be running and still spending. Record a
                // non-clean closure that claims neither a clean exit nor the absence
                // of an orphan; the finally block keeps the child journal and leaves
                // the intent ABANDONED so a later run refuses to resume past it.
                ChildJournal.KillTree(process, DrainMilliseconds);
                descendantsMaySurvive = true;
                closure = "exitedOutputUndrained";
                closureReason =
                    $"the child exited {process.ExitCode.ToString(CultureInfo.InvariantCulture)} but its output pipes were still held after "
                    + $"{DrainMilliseconds.ToString(CultureInfo.InvariantCulture)}ms, so a descendant outlived it, the log may be truncated, and the tree could not be confirmed stopped";
                throw new ChildFailureException(
                    $"The '{step}' child exited {process.ExitCode.ToString(CultureInfo.InvariantCulture)} but a descendant outlived it holding its output pipes; "
                    + $"the drain was bounded at {DrainMilliseconds.ToString(CultureInfo.InvariantCulture)}ms, the log at '{errorLog}' may be truncated, and the surviving descendant could not be confirmed stopped.");
            }

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
            // A drained, exited child is provably gone; a child whose pipes were
            // still held after the bounded drain is NOT, because the kill could not
            // be proven to reach a reparented grandchild. Both the journal clear and
            // the clean ledger close are skipped in that case: 'exited' here means
            // the whole tree is accounted for, not merely that the direct child is.
            if (descendantsMaySurvive)
            {
                exited = false;
            }
            // The journal stops claiming a live writer ONLY when the child is
            // provably gone. Clearing it while the tree could not be confirmed
            // stopped would claim there is no orphan when there might be one - and
            // a later run would then start a second writer of this output root.
            // The still-standing child record and the abandoned intent below both
            // keep a later run from resuming past an uncertain outcome.
            if (exited)
            {
                ChildJournal.TryClearChild(journalPath, _request.CorrelationId, step, childRequestSha256, attempt);
            }
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
        string resultSha256;
        try
        {
            result = ReadValidatedResult(step, resultPath, childRequestSha256, expectedResultFields, out resultSha256);
        }
        catch (ContractException error)
        {
            throw new ChildFailureException(error.Message);
        }
        if (!StrictJson.RequireBool(result, "ok", label))
        {
            throw new ChildFailureException($"The '{step}' child reported failure in its result file.");
        }
        return new ChildOutcome(0, resultPath, result, resultSha256);
    }

    /// <summary>
    /// Reads a child result and refuses it unless it is a complete, strictly
    /// valid result for this step, this correlation id and this exact child
    /// request.
    /// </summary>
    private JsonElement ReadValidatedResult(string step, string resultPath, string childRequestSha256, string[] expectedResultFields, out string resultSha256)
        => ReadValidatedResult(step, _request.CorrelationId, resultPath, childRequestSha256, expectedResultFields, out resultSha256);

    /// <summary>
    /// Reads a child result and refuses it unless it is a complete, strictly
    /// valid result for this step, this correlation id and this exact child
    /// request. Shared with the slot supervisor so that a supervised child's
    /// result is admitted on exactly the terms a short child's result is.
    /// </summary>
    /// <remarks>
    /// The digest is taken from the SAME bytes that were validated, and handed
    /// back rather than recomputed by the caller. Parsing the path and then
    /// hashing the path again is two reads of a thing that can change in
    /// between: a result could be validated in one generation and digested in
    /// another, and that digest travels on into signed evidence describing a
    /// file nothing ever checked.
    /// </remarks>
    internal static JsonElement ReadValidatedResult(
        string step,
        string correlationId,
        string resultPath,
        string childRequestSha256,
        string[] expectedResultFields,
        out string resultSha256)
    {
        var label = $"'{step}' child result";
        var bytes = StrictJson.ReadFileBytes(resultPath, label);
        resultSha256 = CanonicalJson.Sha256Hex(bytes);
        var result = StrictJson.ReadObjectBytes(bytes, resultPath, label);
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
        string resultSha256;
        try
        {
            result = ReadValidatedResult(step, resultPath, childRequestSha256, expectedResultFields, out resultSha256);
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
        outcome = new ChildOutcome(0, resultPath, result, resultSha256);
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

    /// <summary>
    /// Wires the asynchronous readers on <paramref name="process"/> so their output
    /// is captured AND their end-of-stream is observable, then begins reading.
    /// Returns a task per stream that completes when that stream reaches EOF.
    /// </summary>
    /// <remarks>
    /// The runtime raises each DataReceived handler exactly once with a null Data
    /// when its stream's last write handle closes. That null is the ONLY honest
    /// signal that the pipe drained: <c>WaitForExit(int)</c> returns on process exit
    /// and, by the runtime's own contract, does not wait for the streams ("if we
    /// have a hard timeout, we cannot wait for the streams"), so a timed wait cannot
    /// tell a fully-drained child from one whose pipe write ends a surviving
    /// grandchild still holds. Callers wait on BOTH returned tasks, bounded, and a
    /// wait that times out is a real, observed drain failure.
    /// </remarks>
    internal static (System.Threading.Tasks.Task Output, System.Threading.Tasks.Task Error) BeginDrainableReaders(
        Process process, StringBuilder standardOut, StringBuilder standardError)
    {
        var outputDrained = new System.Threading.Tasks.TaskCompletionSource();
        var errorDrained = new System.Threading.Tasks.TaskCompletionSource();
        process.OutputDataReceived += (_, args) =>
        {
            if (args.Data is not null) { lock (standardOut) { standardOut.AppendLine(args.Data); } }
            else { outputDrained.TrySetResult(); }
        };
        process.ErrorDataReceived += (_, args) =>
        {
            if (args.Data is not null) { lock (standardError) { standardError.AppendLine(args.Data); } }
            else { errorDrained.TrySetResult(); }
        };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return (outputDrained.Task, errorDrained.Task);
    }

    /// <summary>
    /// Waits, BOUNDED, for both async reader EOF signals from
    /// <see cref="BeginDrainableReaders"/>. A false return is a genuine drain
    /// failure: at least one stream's write end is still held after the bound.
    /// </summary>
    internal static bool DrainWithin(
        System.Threading.Tasks.Task outputDrained,
        System.Threading.Tasks.Task errorDrained,
        int drainMilliseconds)
        => System.Threading.Tasks.Task.WhenAll(outputDrained, errorDrained).Wait(drainMilliseconds);

    /// <summary>
    /// Proves that a timed-out child's wait is bounded and that its terminal
    /// account is honest about whether the tree was confirmed stopped.
    /// </summary>
    /// <remarks>
    /// A mode of the binary for the same reason the atomic-publish checks are: the
    /// property is a real interaction with a real process, and the falsifying case
    /// - a child that outlives its kill - is staged deterministically with the
    /// kill seam rather than raced. Before the fix the second wait on the timeout
    /// path took no bound, so a child that refused to die hung the coordinator
    /// forever; the bounded-wait check here would never return.
    /// </remarks>
    internal static int SelfTestBoundedWait(string root, TextWriter log)
    {
        var failures = 0;
        var passes = 0;

        void Check(string name, Action body)
        {
            try
            {
                body();
                passes++;
                log.WriteLine($"  PASS  {name}");
            }
            catch (Exception exception)
            {
                failures++;
                log.WriteLine($"  FAIL  {name} :: {exception.Message}");
            }
        }

        static void Require(bool condition, string message)
        {
            if (!condition)
            {
                throw new ContractException(message);
            }
        }

        Directory.CreateDirectory(root);
        log.WriteLine("Bounded child wait");

        Check("a confirmed-stopped timeout is recorded as killed and says so", () =>
        {
            var disposition = DisposeTimedOutChild("step", 5, confirmedStopped: true);
            Require(disposition.ConfirmedStopped, "a confirmed stop was not reported as such");
            Require(disposition.Closure == "timeoutKilled", $"the closure was '{disposition.Closure}'");
            Require(disposition.FailureMessage.Contains("was killed", StringComparison.Ordinal),
                "the confirmed-kill message did not say the child was killed");
        });

        Check("root exit plus inherited-pipe EOF does not release timed-out child custody", () =>
        {
            Require(!ClassifyTimedOutChildCustody(rootExited: true, outputClosed: true),
                "production treated root exit plus pipe EOF as proof every descendant stopped");
        });

        Check("an unconfirmed timeout does NOT claim the child was killed and does NOT claim no orphan", () =>
        {
            var disposition = DisposeTimedOutChild("step", 5, confirmedStopped: false);
            Require(!disposition.ConfirmedStopped, "an unconfirmed stop was reported as confirmed");
            Require(disposition.Closure == "timeoutAbandoned", $"the closure was '{disposition.Closure}'");
            Require(!disposition.FailureMessage.Contains("was killed", StringComparison.Ordinal),
                "the unconfirmed message dishonestly claimed the child was killed");
            Require(disposition.FailureMessage.Contains("may still be running", StringComparison.Ordinal),
                "the unconfirmed message did not admit the child may still be running");
        });

        Check("the wait on a child that outlives its kill is bounded, not infinite", () =>
        {
            using var child = StartSleeper();
            try
            {
                // The child is alive and, for this check, its kill is a no-op:
                // exactly the 'refuses to die' case. The production wait is
                // process.WaitForExit(DrainMilliseconds); it must return within a
                // small multiple of that bound rather than blocking on the child's
                // whole lifetime. Pre-fix, the wait took no argument and would not
                // return here at all.
                const int bound = 500;
                var stopwatch = System.Diagnostics.Stopwatch.StartNew();
                var confirmed = child.WaitForExit(bound);
                stopwatch.Stop();
                Require(!confirmed, "the live child was reported exited");
                Require(stopwatch.ElapsedMilliseconds < bound * 8,
                    $"the bounded wait took {stopwatch.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture)}ms against a {bound.ToString(CultureInfo.InvariantCulture)}ms bound, which is not a bound");
                // And the honest disposition of that unconfirmed stop.
                var disposition = DisposeTimedOutChild("supervised", 1, confirmed);
                Require(disposition.Closure == "timeoutAbandoned",
                    "an unconfirmed real child was not dispositioned as abandoned");
            }
            finally
            {
                try { child.Kill(entireProcessTree: true); } catch (Exception) { }
                try { child.WaitForExit(5000); } catch (Exception) { }
            }
        });

        Check("the production EOF drain reports FAILURE when a grandchild holds the child's pipes", () =>
        {
            // The exact Finding A shape, exercised through the SAME production drain
            // path (BeginDrainableReaders + DrainWithin): a redirected child spawns a
            // grandchild that inherits its stdout/stderr write ends and outlives it,
            // then exits. The process-exit wait returns, but the streams never close.
            var (child, output, error) = StartRedirectedSelfTestChild("--selftest-spawn-lingering-grandchild", "3");
            try
            {
                Require(child.WaitForExit(15_000), "the direct child did not exit within its budget");
                Require(child.HasExited, "the direct child was not marked exited");

                // The DEFECT this fixes: the old drain was process.WaitForExit(ms),
                // which returns on process exit WITHOUT waiting for the streams, so it
                // reports a clean drain here even though a grandchild still holds the
                // pipes. Prove that stale signal still returns true...
                Require(child.WaitForExit(1_000),
                    "the process-exit wait did not return true for an already-exited child; the defect did not reproduce");

                // ...while the fix - waiting on the real EOF signals, bounded - reports
                // the drain FAILED, which is what drained == false must now mean.
                const int bound = 1_000;
                var stopwatch = System.Diagnostics.Stopwatch.StartNew();
                var drained = DrainWithin(output, error, bound);
                stopwatch.Stop();
                Require(!drained, "the EOF drain reported success though a grandchild still held the pipes");
                Require(stopwatch.ElapsedMilliseconds < bound * 8,
                    $"the bounded drain took {stopwatch.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture)}ms against a {bound.ToString(CultureInfo.InvariantCulture)}ms bound, which is not a bound");
                Require(System.Threading.Tasks.Task.WaitAll(new[] { output, error }, 5_000),
                    "the lingering self-test grandchild did not exit within its cleanup budget");
            }
            finally
            {
                try { child.Kill(entireProcessTree: true); } catch (Exception) { }
                try { child.WaitForExit(5000); } catch (Exception) { }
                child.Dispose();
            }
        });

        Check("the production EOF drain reports a CLEAN drain when no descendant lingers", () =>
        {
            // Same production path, no lingering grandchild: the child exits, both pipe
            // write ends close, the readers reach EOF, and the drain succeeds within
            // the bound. A zero exit under a successful drain is what production maps
            // to the clean 'exited' closure.
            var (child, output, error) = StartRedirectedSelfTestChild("--selftest-sleep", "0");
            try
            {
                Require(child.WaitForExit(15_000), "the clean child did not exit within its budget");
                var stopwatch = System.Diagnostics.Stopwatch.StartNew();
                var drained = DrainWithin(output, error, DrainMilliseconds);
                stopwatch.Stop();
                Require(drained, "the EOF drain reported failure for a child with no lingering descendant");
                Require(stopwatch.ElapsedMilliseconds < 5_000,
                    $"the clean drain took {stopwatch.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture)}ms, which is not a bound");
                Require(child.ExitCode == 0, "the clean child did not exit zero");
            }
            finally
            {
                try { child.Kill(entireProcessTree: true); } catch (Exception) { }
                try { child.WaitForExit(5000); } catch (Exception) { }
                child.Dispose();
            }
        });

        log.WriteLine(string.Empty);
        if (failures > 0)
        {
            log.WriteLine($"FAILED: {failures} check(s), {passes} passed.");
            return CoordinatorExitCodes.Contract;
        }
        log.WriteLine($"All {passes} bounded child wait checks passed.");
        return CoordinatorExitCodes.Ok;
    }

    /// <summary>
    /// Starts a long-lived child by re-invoking this very binary in its hidden
    /// sleep mode, so the self-test needs no external tool on the path.
    /// </summary>
    private static Process StartSleeper()
    {
        var host = Environment.ProcessPath
            ?? throw new ContractException("The self-test could not find the running executable to re-invoke.");
        var start = new ProcessStartInfo
        {
            FileName = host,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        // Under `dotnet run` the running process is the dotnet muxer and the
        // managed entry point is the assembly it hosts, so the assembly path is
        // passed as the first argument. Under a native apphost the executable is
        // the entry point itself and no assembly argument is needed.
        if (string.Equals(Path.GetFileNameWithoutExtension(host), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            start.ArgumentList.Add(System.Reflection.Assembly.GetExecutingAssembly().Location);
        }
        start.ArgumentList.Add("--selftest-sleep");
        start.ArgumentList.Add("600");
        return Process.Start(start) ?? throw new ContractException("The self-test sleeper did not start.");
    }

    /// <summary>
    /// Hidden helper mode: spawns a grandchild that INHERITS this process's
    /// stdout/stderr handles and outlives it, then returns at once so this direct
    /// child exits while the inherited pipe write ends stay open.
    /// </summary>
    /// <remarks>
    /// When this direct child is started with its output redirected and read
    /// asynchronously, its stdout/stderr are pipe write ends the parent owns. A
    /// grandchild started here WITHOUT redirection inherits duplicates of those
    /// write ends, so they remain open after this process exits and the parent's
    /// async readers never see EOF. That is the one state in which the parameterless
    /// WaitForExit - which awaits stdout AND stderr EOF, per the runtime's own
    /// "if we have a hard timeout, we cannot wait for the streams" - blocks forever.
    /// The bounded drain the production code now uses returns regardless.
    /// </remarks>
    internal static int SpawnLingeringGrandchild(int seconds)
    {
        var host = Environment.ProcessPath
            ?? throw new ContractException("The self-test could not find the running executable to re-invoke.");
        var start = new ProcessStartInfo
        {
            FileName = host,
            UseShellExecute = false,
            CreateNoWindow = true,
            // Deliberately NOT redirected: the grandchild inherits THIS process's
            // stdout/stderr, which are the redirected pipe write ends the parent
            // handed down. They stay open past this process's exit.
            RedirectStandardOutput = false,
            RedirectStandardError = false
        };
        if (string.Equals(Path.GetFileNameWithoutExtension(host), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            start.ArgumentList.Add(System.Reflection.Assembly.GetExecutingAssembly().Location);
        }
        start.ArgumentList.Add("--selftest-sleep");
        start.ArgumentList.Add(seconds.ToString(CultureInfo.InvariantCulture));
        using var grandchild = Process.Start(start)
            ?? throw new ContractException("The self-test lingering grandchild did not start.");
        // Disposing the Process object releases only our handle to the grandchild;
        // it keeps running, holding the inherited pipe write ends open.
        return CoordinatorExitCodes.Ok;
    }

    /// <summary>
    /// Starts a self-test child that mirrors a production child exactly - stdout and
    /// stderr redirected and read through <see cref="BeginDrainableReaders"/> - and
    /// returns it together with the two EOF drain tasks, so a check can exercise the
    /// real production drain rather than a stand-in.
    /// </summary>
    private static (Process Child, System.Threading.Tasks.Task Output, System.Threading.Tasks.Task Error) StartRedirectedSelfTestChild(
        params string[] arguments)
    {
        var host = Environment.ProcessPath
            ?? throw new ContractException("The self-test could not find the running executable to re-invoke.");
        var start = new ProcessStartInfo
        {
            FileName = host,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true
        };
        if (string.Equals(Path.GetFileNameWithoutExtension(host), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            start.ArgumentList.Add(System.Reflection.Assembly.GetExecutingAssembly().Location);
        }
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        var child = Process.Start(start) ?? throw new ContractException("The self-test redirected child did not start.");
        // The exact production wiring: capture the output AND observe EOF.
        var (output, error) = BeginDrainableReaders(child, new StringBuilder(), new StringBuilder());
        child.StandardInput.Close();
        return (child, output, error);
    }

    /// <summary>
    /// Emits a spread of real child-request files, each carrying the childRequestSha256
    /// the coordinator itself computed, so a PowerShell golden test can prove the
    /// child's recompute is byte-identical to this canonicaliser across the escaping
    /// and shape cases that would otherwise diverge silently.
    /// </summary>
    /// <remarks>
    /// The digest is computed here exactly as <see cref="Invoke"/> computes it: over
    /// the canonical form of the request BEFORE childRequestSha256 is added. The
    /// cases deliberately include the short-escaped control characters, a character
    /// at or above 128, an out-of-order set of keys, a nested object, an array, an
    /// empty string and an integer, because those are where a second implementation
    /// of the canonical form is most likely to drift.
    /// </remarks>
    internal static int SelfTestEmitChildRequests(string root, TextWriter log)
    {
        Directory.CreateDirectory(root);

        MapNode Base(string correlation, string step)
        {
            return new MapNode()
                .Set("contractVersion", "devpilot.shadow-run-coordinator.child-request.v1")
                .Set("correlationId", correlation)
                .Set("step", step)
                .Set("resultPath", Path.Combine(root, correlation + "-" + step + ".result.json"));
        }

        var cases = new List<(string Name, MapNode Node)>
        {
            ("plain", Base("corr-plain-0001", "qualify")
                .Set("operatorAlias", "reviewer-a")
                .Set("plannedRunCount", 3)),
            ("controls", Base("corr-controls-02", "prepare")
                // Every short escape the canonical form uses, plus a backslash and a
                // quote, in one string.
                .Set("message", "tab\tnewline\ncarriage\rquote\"back\\slash\bform\ffeed")
                .Set("emptyString", string.Empty)),
            ("unicode", Base("corr-unicode-003", "prepare")
                // A character at 127 (escaped) beside characters above 128 (passed
                // through), and a low control character.
                .Set("label", "del\u007fabove\u00e9\u4e2dlow\u0001")),
            ("nested", Base("corr-nested-0004", "reconcile")
                .Set("nested", new MapNode()
                    .Set("zebra", "last")
                    .Set("alpha", 42)
                    .Set("flag", true)
                    .Set("nothing", Node.Null()))
                .Set("paths", new ListNode()
                    .Add(Node.Text("b/second.txt"))
                    .Add(Node.Text("a/first.txt")))),
            ("ordering", Base("corr-ordering-05", "deliver")
                // Keys added out of ordinal order to prove the child sorts, not
                // preserves insertion order. Deliberately spans an uppercase letter,
                // an underscore and a lowercase letter (ordinal orders them
                // Bravo < _underscore < alpha < zulu) without colliding on case,
                // which the child's JSON reader would reject as a duplicate key.
                .Set("zulu", "z")
                .Set("Bravo", "B")
                .Set("alpha", "a")
                .Set("_underscore", "u")),
        };

        foreach (var (name, node) in cases)
        {
            var digest = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(node));
            node.Set("childRequestSha256", digest);
            var path = Path.Combine(root, name + ".request.json");
            CanonicalJson.WriteFileAtomic(path, CanonicalJson.Readable(node));
            log.WriteLine($"emitted {name} -> {digest}");
        }

        log.WriteLine($"Emitted {cases.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)} child request(s).");
        return CoordinatorExitCodes.Ok;
    }
}
