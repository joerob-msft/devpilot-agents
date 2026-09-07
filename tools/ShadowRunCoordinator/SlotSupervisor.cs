using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The budgets one supervised slot is watched against, every one of them read
/// out of the signed qualification plan rather than out of the request.
/// </summary>
/// <remarks>
/// A caller who could set these could give itself an unbounded run by writing a
/// larger number in its own request. So the numbers come from the plan the
/// declaration was signed over, and the only thing the request contributes is
/// the grace: how long the supervisor waits PAST the plan's own deadline before
/// concluding that the owner failed to stop its own run.
///
/// The grace is what keeps authority where it belongs. PowerShell's own timeout
/// fires first and writes the authoritative terminal artifact that records the
/// run as timed out; the supervisor's tree kill is a backstop for the case where
/// that did not happen, and it produces no verdict of its own.
/// </remarks>
internal sealed record SlotDeadlines(int HardSeconds, int ActivitySeconds, int PerCallSeconds, int GraceSeconds)
{
    /// <summary>When the supervisor stops waiting, counted from the child's start.</summary>
    internal TimeSpan SupervisionBudget => TimeSpan.FromSeconds((long)HardSeconds + GraceSeconds);

    /// <summary>When the supervisor stops waiting on a silent child, or zero when disabled.</summary>
    internal TimeSpan ActivityBudget => ActivitySeconds <= 0
        ? TimeSpan.Zero
        : TimeSpan.FromSeconds((long)ActivitySeconds + GraceSeconds);

    internal MapNode Describe() => new MapNode()
        .Set("hardSeconds", HardSeconds)
        .Set("activitySeconds", ActivitySeconds)
        .Set("perCallSeconds", PerCallSeconds)
        .Set("graceSeconds", GraceSeconds);

    /// <summary>
    /// Refuses a plan whose budgets cannot bound the work they claim to bound.
    /// A per-call budget larger than the hard budget means the hard deadline can
    /// never be the thing that stops a stuck call, which would leave the
    /// supervisor's kill as the only stop - and a kill writes no terminal.
    /// </summary>
    internal void RequireConsistent(string label)
    {
        if (HardSeconds <= 0)
        {
            throw new ContractException($"The {label} carries a hard budget of {HardSeconds.ToString(CultureInfo.InvariantCulture)} seconds, which bounds nothing.");
        }
        if (PerCallSeconds > HardSeconds)
        {
            throw new ContractException(
                $"The {label} allows a single call {PerCallSeconds.ToString(CultureInfo.InvariantCulture)} seconds inside a run bounded at " +
                $"{HardSeconds.ToString(CultureInfo.InvariantCulture)} seconds, so the run's own deadline could never stop a stuck call.");
        }
        if (ActivitySeconds > 0 && ActivitySeconds > HardSeconds)
        {
            throw new ContractException(
                $"The {label} allows {ActivitySeconds.ToString(CultureInfo.InvariantCulture)} seconds of silence inside a run bounded at " +
                $"{HardSeconds.ToString(CultureInfo.InvariantCulture)} seconds, so the silence deadline can never fire.");
        }
    }
}

/// <summary>What one supervised child was observed to do. None of it is a verdict.</summary>
internal sealed record SlotObservation(
    string Disposition,
    int ExitCode,
    bool KilledBySupervisor,
    int ProcessId,
    string StartedAtUtc,
    string EndedAtUtc,
    long ObservedSeconds,
    bool Adopted)
{
    internal const string Exited = "exited";
    internal const string HardDeadlineKill = "hardDeadlineKill";
    internal const string ActivityDeadlineKill = "activityDeadlineKill";
    internal const string Vanished = "vanished";

    internal MapNode Describe() => new MapNode()
        .Set("disposition", Disposition)
        .Set("childExitCode", ExitCode)
        .Set("killedBySupervisor", KilledBySupervisor)
        .Set("childProcessId", ProcessId)
        .Set("childStartedAtUtc", StartedAtUtc)
        .Set("childEndedAtUtc", EndedAtUtc)
        .Set("observedSeconds", ObservedSeconds)
        .Set("observedAcrossRestart", Adopted);
}

/// <summary>A supervised child that has been started and not yet waited on.</summary>
internal sealed record SlotLaunch(
    string Step,
    string RequestPath,
    string ResultPath,
    string JournalPath,
    string OutLogPath,
    string ErrorLogPath,
    string ChildRequestSha256,
    int Attempt,
    int ProcessId,
    string StartedAtUtc,
    bool Adopted)
{
    internal MapNode DescribeIdentity() => new MapNode()
        .Set("childProcessId", ProcessId)
        .Set("childStartedAtUtc", StartedAtUtc)
        .Set("childRequestSha256", ChildRequestSha256)
        .Set("attempt", Attempt);
}

/// <summary>
/// Supervision of the one long-running child, split so that a crash between
/// starting it and waiting for it is survivable.
/// </summary>
/// <remarks>
/// The short-step invoker starts a child and waits for it in a single call,
/// which is fine when the child is seconds long: a coordinator that dies mid-step
/// simply retries the step. A qualification slot is not like that. It is
/// minutes-to-hours long, it consumes a single-use launch authorization, and the
/// PowerShell owner makes its attempt record with CreateNew before the work
/// begins - so a retry is not available, and a coordinator that dies must be able
/// to come back and find the child it left running.
///
/// Hence two phases. <see cref="Start"/> starts the child and returns as soon as
/// its identity is durable. <see cref="Await"/> watches it, and can watch a child
/// this process did not start by re-deriving liveness from the recorded identity.
/// Between the two, the caller commits the identity to signed state; that commit
/// is what makes the restart path possible.
///
/// The supervisor forms no opinion about the run. It reports what it saw - an
/// exit code, a disposition, times - and the artifact the PowerShell owner wrote
/// remains the only statement about what the run means.
/// </remarks>
internal sealed class SlotSupervisor(CoordinatorRequest request, LaunchLedger ledger)
{
    /// <summary>How often the supervisor looks at a child it is watching.</summary>
    private const int PollMilliseconds = 500;

    private readonly CoordinatorRequest _request = request;
    private readonly LaunchLedger _ledger = ledger;
    private readonly StringBuilder _standardOut = new();
    private readonly StringBuilder _standardError = new();
    private Process? _process;

    /// <summary>Children this process actually started, as opposed to ones it adopted.</summary>
    internal int LaunchCount { get; private set; }

    /// <summary>
    /// Starts the supervised child and returns once its identity is recorded.
    /// Nothing is waited for here, so the caller can make the identity durable
    /// before the long wait begins.
    /// </summary>
    internal SlotLaunch Start(string step, string scriptPath, MapNode childRequest)
    {
        if (_process is not null)
        {
            throw new ContractException("The slot supervisor already has a child in flight; it supervises exactly one.");
        }

        var stem = Path.Combine(_request.ExchangeRoot, $"{_request.CorrelationId}-{step}");
        var requestPath = stem + ".request.json";
        var resultPath = stem + ".result.json";
        var journalPath = stem + ".journal.json";
        var outLog = Path.Combine(_request.LogRoot, $"{_request.CorrelationId}-{step}.out.log");
        var errorLog = Path.Combine(_request.LogRoot, $"{_request.CorrelationId}-{step}.err.log");

        Directory.CreateDirectory(_request.ExchangeRoot);
        Directory.CreateDirectory(_request.LogRoot);

        var payload = childRequest
            .Set("contractVersion", "devpilot.shadow-run-coordinator.child-request.v1")
            .Set("correlationId", _request.CorrelationId)
            .Set("step", step)
            .Set("resultPath", resultPath);
        // The digest is taken over the request as it stands before the field that
        // carries it, exactly as the short-step invoker does, so the adapter can
        // echo it back and bind its result to the request that asked for the work.
        var childRequestSha256 = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(payload));
        payload.Set("childRequestSha256", childRequestSha256);
        CanonicalJson.WriteFileAtomic(requestPath, CanonicalJson.Readable(payload));

        // A result left behind by an earlier attempt is never adopted for a
        // supervised slot. The launch authorization is single-use, so "this
        // already succeeded" is a claim that has to be settled against the
        // artifacts the owner wrote, not against a file at a predictable path.
        if (File.Exists(resultPath))
        {
            File.Delete(resultPath);
        }

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

        // The supervised launch is the one this coordinator can least afford to
        // repeat: the authorization is single-use and the owner mints its attempt
        // record before it works. So the intent goes down first here for exactly
        // the reason it does for a short step, and it matters more.
        var intent = _ledger.Open(step, childRequestSha256, start, requestPath, resultPath);

        LaunchCount++;
        Process process;
        try
        {
            process = Process.Start(start) ?? throw new ChildFailureException($"The '{step}' supervised child did not start.");
        }
        catch (Exception error)
        {
            _ledger.RecordNotStarted(intent, error.Message);
            throw;
        }
        _process = process;
        // The start time is half of the child's identity: without it the journal
        // records nothing a later run can recognise, and a resumed run would have
        // only a process id, which the operating system reuses. A child that
        // cannot be identified cannot be supervised across a restart, so it is
        // stopped here rather than left running unowned.
        //
        // Everything between the start and the journal write is guarded, because a
        // fault in any of it leaves a supervised reviewer already running against
        // this output root with nothing holding it. A ledger write can fail on a
        // full disk or a locked directory as readily as anything else, and letting
        // that escape would trade a recorded child for an unowned one - the exact
        // outcome the unidentifiable-child branch below kills a child to avoid.
        string startedAtUtc;
        try
        {
            startedAtUtc = ChildJournal.StartedAtUtc(process);
            // Recorded before the identity is judged, so that even a child whose
            // start time this account cannot read is named by its process id in
            // the ledger rather than disappearing into the unknown case.
            _ledger.RecordStart(intent, process);
        }
        catch
        {
            var tornDown = false;
            try
            {
                ChildJournal.KillTree(process, ChildToolInvoker.DrainMilliseconds);
                tornDown = process.HasExited;
            }
            catch
            {
                tornDown = false;
            }
            finally
            {
                process.Dispose();
                _process = null;
                ChildJournal.TryClearChild(journalPath, _request.CorrelationId, step, childRequestSha256, attempt);
                if (tornDown)
                {
                    _ledger.Close(step, "unrecorded", "the child's identity could not be recorded, so it was stopped");
                }
                else
                {
                    _ledger.Abandon(step, "the child's identity could not be recorded and its tree could not be confirmed stopped");
                }
            }
            throw;
        }
        if (startedAtUtc.Length == 0)
        {
            var stopped = false;
            try
            {
                ChildJournal.KillTree(process, ChildToolInvoker.DrainMilliseconds);
                stopped = process.HasExited;
            }
            finally
            {
                process.Dispose();
                _process = null;
                ChildJournal.TryClearChild(journalPath, _request.CorrelationId, step, childRequestSha256, attempt);
                // Only a confirmed exit closes this. A child with no readable
                // start time is one no later run can recognise, so if the kill
                // could not be confirmed there is a supervised writer of this
                // output root that nothing can name - and 'closed' would tell the
                // next run it may start a second one.
                if (stopped)
                {
                    _ledger.Close(step, "unidentifiable", "the child's start time could not be read, so it was stopped");
                }
                else
                {
                    _ledger.Abandon(step, "the child's start time could not be read and its tree could not be confirmed stopped");
                }
            }
            throw new ChildFailureException(
                $"The '{step}' supervised child started as process {process.Id.ToString(CultureInfo.InvariantCulture)} but its start time could not be read, so it could not be identified after a restart. It was stopped.");
        }
        ChildJournal.Write(journalPath, _request.CorrelationId, step, childRequestSha256, attempt, process);
        process.OutputDataReceived += (_, args) => { if (args.Data is not null) { lock (_standardOut) { _standardOut.AppendLine(args.Data); } } };
        process.ErrorDataReceived += (_, args) => { if (args.Data is not null) { lock (_standardError) { _standardError.AppendLine(args.Data); } } };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.StandardInput.Close();

        return new SlotLaunch(
            step,
            requestPath,
            resultPath,
            journalPath,
            outLog,
            errorLog,
            childRequestSha256,
            attempt,
            process.Id,
            startedAtUtc,
            Adopted: false);
    }

    /// <summary>
    /// Rebuilds the handle for a child a previous run started, from the identity
    /// that run committed. Nothing is launched.
    /// </summary>
    internal SlotLaunch Adopt(string step, string childRequestSha256, int processId, string startedAtUtc)
    {
        // Adoption without a start time would let a recycled process id be waited
        // on, and later killed, as though it were the child.
        if (startedAtUtc.Length == 0)
        {
            throw new ContractException($"A '{step}' child cannot be adopted without the start time that identifies it.");
        }
        var stem = Path.Combine(_request.ExchangeRoot, $"{_request.CorrelationId}-{step}");
        return new SlotLaunch(
            step,
            stem + ".request.json",
            stem + ".result.json",
            stem + ".journal.json",
            Path.Combine(_request.LogRoot, $"{_request.CorrelationId}-{step}.out.log"),
            Path.Combine(_request.LogRoot, $"{_request.CorrelationId}-{step}.err.log"),
            childRequestSha256,
            ChildJournal.ReadAttempt(stem + ".journal.json", _request.CorrelationId, step, childRequestSha256),
            processId,
            startedAtUtc,
            Adopted: true);
    }

    /// <summary>
    /// Watches the launched child until it exits or a deadline says to stop
    /// waiting, and reports what happened without interpreting it.
    /// </summary>
    /// <param name="launch">The child to watch, started here or by a previous run.</param>
    /// <param name="deadlines">Budgets from the signed plan, plus this request's grace.</param>
    /// <param name="progressPath">
    /// The directory the owner writes into as it works. Its newest write time is
    /// the only activity signal the supervisor uses, because standard output is
    /// captured for humans and must never feed a decision.
    /// </param>
    internal SlotObservation Await(SlotLaunch launch, SlotDeadlines deadlines, string progressPath)
    {
        var startedAt = ParseStartedAt(launch.StartedAtUtc);
        var lastProgress = LatestProgressUtc(progressPath) ?? startedAt;
        var disposition = SlotObservation.Exited;
        var killed = false;
        var exitCode = -1;
        // A child this run never held a handle for - one it adopted and then
        // observed vanish - has no exit to wait on here, so the teardown below
        // asks the operating system instead of assuming either answer.
        var exited = true;

        try
        {
            while (true)
            {
                if (HasFinished(launch, out var observedExit))
                {
                    exitCode = observedExit;
                    disposition = _process is null && observedExit == -1 ? SlotObservation.Vanished : SlotObservation.Exited;
                    break;
                }

                var now = DateTime.UtcNow;
                if (now - startedAt > deadlines.SupervisionBudget)
                {
                    disposition = SlotObservation.HardDeadlineKill;
                    killed = Stop(launch);
                    break;
                }
                var progress = LatestProgressUtc(progressPath);
                if (progress is { } seen && seen > lastProgress)
                {
                    lastProgress = seen;
                }
                if (deadlines.ActivityBudget > TimeSpan.Zero && now - lastProgress > deadlines.ActivityBudget)
                {
                    disposition = SlotObservation.ActivityDeadlineKill;
                    killed = Stop(launch);
                    break;
                }
                Thread.Sleep(PollMilliseconds);
            }
        }
        finally
        {
            // The journal clear is the one thing that MUST happen: a journal left
            // naming a live child refuses every later run against this root. So
            // the process teardown - any part of which can still throw - is
            // wrapped, and the clear runs whatever it did.
            try
            {
                if (_process is not null)
                {
                    if (!_process.HasExited)
                    {
                        ChildJournal.KillTree(_process, ChildToolInvoker.DrainMilliseconds);
                    }
                    // A bounded drain, then the logs are written under the same locks
                    // the readers append under. Reading a StringBuilder that an
                    // asynchronous reader can still be appending to is a data race,
                    // and this path must not turn a supervised timeout into a crash.
                    _process.WaitForExit(ChildToolInvoker.DrainMilliseconds);
                    exited = _process.HasExited;
                    WriteLogs(launch);
                    _process.Dispose();
                    _process = null;
                }
                else
                {
                    // The adopted child - the resumed-run path, where this process
                    // never held a handle. Every deadline kill above went through
                    // ChildJournal.KillTree, which is best effort and returns
                    // quietly whether or not the tree went, so 'stopped it' is not
                    // an answer this can take from its own call. The process table
                    // is asked instead, over the recorded identity, which is the
                    // same question a later run would ask. Without this the one
                    // path that needs 'abandoned' - a supervised reviewer that
                    // survived a kill on a root this run is about to declare
                    // closed - could never reach it.
                    exited = !ChildJournal.IsAlive(
                        new RecordedChild(launch.Step, launch.ProcessId, launch.StartedAtUtc, launch.JournalPath));
                }
            }
            finally
            {
                ChildJournal.TryClearChild(launch.JournalPath, _request.CorrelationId, launch.Step, launch.ChildRequestSha256, launch.Attempt);
                // Addressed by step rather than by handle, because a resumed run
                // is closing an intent a PREVIOUS process opened. That is the case
                // that would otherwise leave a supervised launch open forever and
                // wedge every later run against this root. A tree this run could
                // not confirm stopped is recorded as abandoned instead: the slot
                // authorization is single-use, so re-authorizing it over a child
                // that may still be alive is the worst outcome available here.
                if (exited)
                {
                    _ledger.Close(launch.Step, disposition, killed ? "the supervisor stopped the child on a plan deadline" : "the child was observed to stop");
                }
                else
                {
                    _ledger.Abandon(
                        launch.Step,
                        killed
                            ? "the supervisor stopped the child on a plan deadline and its tree could not be confirmed stopped"
                            : "the supervisor could not confirm the child's tree had stopped");
                }
            }
        }

        var endedAt = DateTime.UtcNow;
        return new SlotObservation(
            disposition,
            exitCode,
            killed,
            launch.ProcessId,
            launch.StartedAtUtc,
            endedAt.ToString("O", CultureInfo.InvariantCulture),
            (long)(endedAt - startedAt).TotalSeconds,
            launch.Adopted);
    }

    /// <summary>
    /// The child's result file, admitted on exactly the terms a short step's
    /// result is. Absent or malformed is a failure of the child, and is reported
    /// as such rather than as a request problem.
    /// </summary>
    internal ChildOutcome ReadResult(SlotLaunch launch, params string[] expectedResultFields)
    {
        try
        {
            var result = ChildToolInvoker.ReadValidatedResult(
                launch.Step,
                _request.CorrelationId,
                launch.ResultPath,
                launch.ChildRequestSha256,
                expectedResultFields,
                out var resultSha256);
            if (!StrictJson.RequireBool(result, "ok", $"'{launch.Step}' child result"))
            {
                throw new ChildFailureException($"The '{launch.Step}' supervised child reported failure in its result file.");
            }
            return new ChildOutcome(0, launch.ResultPath, result, resultSha256);
        }
        catch (ContractException error)
        {
            throw new ChildFailureException(error.Message);
        }
    }

    private bool HasFinished(SlotLaunch launch, out int exitCode)
    {
        exitCode = -1;
        if (_process is not null)
        {
            if (!_process.WaitForExit(0))
            {
                return false;
            }
            exitCode = _process.ExitCode;
            return true;
        }
        // No handle, because a previous run started this child. Liveness is
        // re-derived from the process table using id AND start time together, so
        // a recycled id cannot be mistaken for the child. Its exit code is not
        // available to this process, which is exactly why the exit code is never
        // the thing a decision rests on: the artifact the owner wrote is.
        return !ChildJournal.IsAlive(new RecordedChild(launch.Step, launch.ProcessId, launch.StartedAtUtc, launch.JournalPath));
    }

    private bool Stop(SlotLaunch launch)
    {
        if (_process is not null)
        {
            ChildJournal.KillTree(_process, ChildToolInvoker.DrainMilliseconds);
            return true;
        }
        // An adopted child still has to be stoppable, or a restart would turn a
        // bounded run into an unbounded one.
        try
        {
            using var adopted = Process.GetProcessById(launch.ProcessId);
            if (!ChildJournal.IsSameProcess(adopted, launch.StartedAtUtc))
            {
                return false;
            }
            ChildJournal.KillTree(adopted, ChildToolInvoker.DrainMilliseconds);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private void WriteLogs(SlotLaunch launch)
    {
        lock (_standardOut)
        {
            File.WriteAllText(launch.OutLogPath, _standardOut.ToString(), StrictJson.StrictUtf8);
        }
        lock (_standardError)
        {
            File.WriteAllText(launch.ErrorLogPath, _standardError.ToString(), StrictJson.StrictUtf8);
        }
    }

    private static DateTime ParseStartedAt(string startedAtUtc)
        => DateTime.TryParse(
            startedAtUtc,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out var parsed)
            ? parsed.ToUniversalTime()
            // An unreadable start time must not become an unbounded wait, so the
            // budget is measured from now instead - later than the truth, never
            // earlier, so the child is never cut short by a clock this process
            // could not read.
            : DateTime.UtcNow;

    /// <summary>
    /// The newest write anywhere under the owner's working directory, or null
    /// when it has not appeared yet.
    /// </summary>
    private static DateTime? LatestProgressUtc(string progressPath)
    {
        if (progressPath.Length == 0 || !Directory.Exists(progressPath))
        {
            return null;
        }
        DateTime? newest = null;
        try
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(progressPath, "*", SearchOption.AllDirectories))
            {
                var written = File.GetLastWriteTimeUtc(entry);
                if (newest is null || written > newest)
                {
                    newest = written;
                }
            }
        }
        catch (IOException)
        {
            // A directory being written while it is walked is normal; an
            // unreadable sample is simply not a progress signal this tick.
            return newest;
        }
        catch (UnauthorizedAccessException)
        {
            return newest;
        }
        return newest;
    }
}
