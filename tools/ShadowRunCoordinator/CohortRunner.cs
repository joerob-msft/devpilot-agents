using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The exit codes this program's two entry modes share.
/// </summary>
/// <remarks>
/// Collected in one place because the cohort runner READS the single-run codes:
/// it has to tell a preparation that refused its request from one whose
/// supervised run ended other than complete, and a runner that carried its own
/// copy of those numbers would silently disagree with the program it launches the
/// first time either changed.
/// </remarks>
internal static class CoordinatorExitCodes
{
    internal const int Ok = 0;
    internal const int Usage = 1;
    internal const int Contract = 2;
    internal const int LeaseConflict = 3;
    internal const int ChildFailure = 4;

    /// <summary>A supervised slot reached a terminal that was not 'complete'. Not a coordinator fault.</summary>
    internal const int SlotNotComplete = 5;

    /// <summary>A previous run's launch was never accounted for, so this one refuses to guess.</summary>
    internal const int UnresolvedLaunch = 6;

    internal const int Halted = 9;

    /// <summary>A cohort stopped on one of its own global budgets; its remaining entries are pending.</summary>
    internal const int CohortBudgetExhausted = 10;

    /// <summary>A cohort observed something that stops the whole set, whatever its stop policy says.</summary>
    internal const int CohortBlocked = 11;
}

/// <summary>
/// Runs one declared cohort, one entry at a time, and accounts for every entry it
/// starts.
/// </summary>
/// <remarks>
/// This class adds no capability. Each entry is the SAME typed preparation this
/// program already performs, started as its own process against its own immutable
/// output root, with its own signed state, its own lease and its own launch
/// ledger; everything a single preparation refuses, a cohort refuses too, because
/// the refusals are still that preparation's.
///
/// What the cohort adds is three things a single preparation cannot do for
/// itself.
///
/// It commits the INTENT to start an entry before the entry's coordinator exists.
/// A runner killed between deciding to start the third entry and that entry
/// writing anything at all leaves no per-entry evidence whatsoever, and without
/// the intent a resume could not tell that from an entry that was never reached.
///
/// It accounts for the SET. Global budgets are checked before each entry from the
/// sealed estimates in the manifest and the actual counts accumulated from
/// entries that have already ended, so a cohort stops on a ceiling with its
/// remaining entries untouched rather than discovering the ceiling after the
/// evidence exists.
///
/// It never re-attempts anything. A stop policy decides whether an unsuccessful
/// entry ends the cohort; neither policy retries an entry, replaces one, or
/// substitutes another subject for one that failed. An entry that ended is
/// closed, and the journal refuses to reopen it.
///
/// There is no judgement here and no capability to write. What crosses back from
/// an entry is an exit code and a published audit of state words, digests and
/// integers, none of which this class compares to a literal or branches on beyond
/// the four exit codes it is required to tell apart.
/// </remarks>
internal sealed class CohortRunner(CohortManifest manifest, string operatorAlias, TextWriter log)
{
    private readonly CohortManifest _manifest = manifest;
    private readonly string _operatorAlias = operatorAlias;
    private readonly TextWriter _log = log;

    /// <summary>Each entry's declared correlation, read from its own request once.</summary>
    private readonly Dictionary<string, string> _correlations = new(StringComparer.Ordinal);

    /// <summary>How long a killed entry tree is given to go before the runner stops waiting on it.</summary>
    private const int DrainMilliseconds = 30_000;

    internal static int Run(CohortManifest manifest, string operatorAlias, bool rebuildOnly, TextWriter log)
    {
        Directory.CreateDirectory(manifest.JournalRoot);
        Directory.CreateDirectory(manifest.IntentRoot);
        Directory.CreateDirectory(manifest.LogRoot);

        // Taken before the journal is read AND before the key is minted, so two
        // runners pointed at one journal root cannot both decide they are the
        // resumer, and cannot race to create the key.
        using var lease = CohortLease.Acquire(manifest);

        if (rebuildOnly && (!File.Exists(manifest.JournalPath) || !File.Exists(manifest.JournalKeyPath)))
        {
            // A rebuild republishes a record; it does not invent one. Without the
            // journal and its key there is nothing to republish, and going ahead
            // would write an index signed with a freshly minted key that nobody
            // else holds - an index no later run and no reader could verify.
            throw new ContractException(
                $"There is no cohort journal at '{manifest.JournalPath}' with a key at '{manifest.JournalKeyPath}' to rebuild an index from. " +
                "A rebuild reports what a run recorded; it does not stand in for one.");
        }

        var key = CohortJournal.LoadOrMintKey(manifest, out var keyPreexisted);
        var journal = CohortJournal.LoadOrFresh(manifest, key, keyPreexisted);
        var runner = new CohortRunner(manifest, operatorAlias, log);

        log.WriteLine(
            $"shadow-cohort-runner cohortId={manifest.CohortId} correlationId={manifest.CorrelationId} " +
            $"entries={manifest.Entries.Count.ToString(CultureInfo.InvariantCulture)} concurrency={manifest.Execution.Concurrency.ToString(CultureInfo.InvariantCulture)} " +
            $"stopPolicy={manifest.Execution.StopPolicy} authorizedBy={operatorAlias}");

        if (rebuildOnly)
        {
            // Rebuilds the index from the signed journal and the per-entry audits
            // and starts nothing. This is the claim the index makes about itself,
            // made executable: an index that could not be rebuilt from the
            // artifacts it names would be an index nobody could check.
            //
            // The outcome is derived from the journal rather than assumed. A
            // rebuild that always said 'completed' would turn a budget stop or a
            // fail-fast stop into a clean cohort every time it was re-published,
            // which is the opposite of what a rebuild is for.
            var (reason, detail) = runner.DeriveOutcome(journal);
            try
            {
                runner.PublishIndexCore(
                    journal,
                    key,
                    reason,
                    detail,
                    journal.HasTerminal ? journal.TerminalDetailSha256 : CanonicalJson.Sha256HexOfText(detail),
                    recordTerminal: false);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // A run treats a failure to write the index leniently, because the
                // journal is authoritative and the next run rewrites the report. A
                // rebuild has no next run to defer to: writing the report is the
                // whole of what it was asked to do, so it says so as a refusal
                // rather than as a fault from underneath.
                throw new ContractException(
                    $"The cohort index at '{manifest.IndexPath}' could not be written: {error.Message} " +
                    "A rebuild publishes the report and does nothing else, so it has not done what it was asked.");
            }
            log.WriteLine($"index rebuilt: {manifest.IndexPath} terminalReason={reason}");
            return CoordinatorExitCodes.Ok;
        }

        return runner.Walk(journal, key);
    }

    /// <summary>
    /// The outcome the journal alone says this cohort reached, without starting
    /// anything.
    /// </summary>
    /// <remarks>
    /// The same words the walk publishes, derived from the same facts: which
    /// entries ended, how they ended, and whether the declared stop policy would
    /// have ended the cohort where it did. This is what lets a rebuilt index be
    /// compared with the one the run published instead of merely resembling it.
    /// </remarks>
    internal (string Reason, string Detail) DeriveOutcome(CohortJournal journal)
    {
        // The word the run published, when it published one. A cohort with
        // entries still pending may have stopped on a ceiling, on an unresolvable
        // launch, on a refusal, or because the runner was killed where it stood,
        // and the records alone cannot tell those apart. The journal carries what
        // was published so a rebuild reports it rather than picking one.
        if (journal.HasTerminal)
        {
            return (journal.TerminalReason, journal.TerminalDetail);
        }

        var anyUnsuccessful = false;
        var anyPending = false;
        var stopped = false;
        foreach (var entry in _manifest.Entries)
        {
            var record = journal.RecordFor(entry.EntryId);
            if (record.EndedRefused)
            {
                return (CohortIndex.ReasonBlocked, "an entry's published evidence was refused and the cohort stopped there");
            }
            if (!record.HasEnded)
            {
                anyPending = true;
                continue;
            }
            if (anyPending)
            {
                // An ended entry after a pending one cannot happen while the walk
                // is sequential, so the journal is describing a set this build did
                // not produce.
                throw new ContractException(
                    $"The cohort journal records entry '{entry.EntryId}' as ended after an earlier entry that never ended. " +
                    "A cohort prepares its entries in declared order, so this journal was not written by this build.");
            }
            if (!record.EndedComplete)
            {
                anyUnsuccessful = true;
                if (_manifest.Execution.StopsOnFirstFailure)
                {
                    stopped = true;
                }
            }
        }

        if (stopped)
        {
            return (CohortIndex.ReasonStoppedOnFailure, "an entry ended other than complete and the declared stop policy ends the cohort there");
        }
        if (anyPending)
        {
            // Nothing here says WHY the walk stopped short, and this line does not
            // pretend to: a journal that never recorded a published word is a
            // journal from a runner that was killed before it published one.
            return (CohortIndex.ReasonRunning, "the cohort did not reach every declared entry and recorded no word about why");
        }
        if (anyUnsuccessful)
        {
            return (CohortIndex.ReasonCompletedWithFailure, "every declared entry was reached and at least one ended other than complete");
        }
        return (CohortIndex.ReasonCompleted, "every declared entry ended complete");
    }

    private int Walk(CohortJournal journal, byte[] key)
    {
        try
        {
            // Written on entry, after every commit, and on every way out -
            // including the ones that are faults. An index that is only written
            // when a cohort ends well is an index that is missing exactly when it
            // is wanted. This one is inside the guard on purpose: it re-reads every
            // ended entry's evidence, so it is one of the places a refusal can be
            // raised, and a refusal raised here has to reach the handler that
            // records it rather than escaping past a journal this call has already
            // moved to 'running'.
            PublishIndexSafely(journal, key, CohortIndex.ReasonRunning, "the cohort is in progress");

            RequireLiveToolkitHead();

            var stopped = false;
            var anyUnsuccessful = false;
            foreach (var entry in _manifest.Entries)
            {
                var record = journal.RecordFor(entry.EntryId);

                if (record.EndedRefused)
                {
                    // A refused entry is not a failed entry that the continue
                    // policy may walk past. Its own published evidence could not be
                    // read as this build's, which says nothing reliable about what
                    // ran in that output root - so the cohort that contains it does
                    // not go on producing more of the same.
                    throw new CohortBlockedException(
                        $"Entry '{entry.EntryId}' ended with its published evidence refused, and a cohort holding an entry whose evidence " +
                        "was refused stays stopped. Settle that entry's artifacts by hand before this cohort is run again.");
                }

                if (record.HasEnded)
                {
                    // Exactly once, across every resume. The ending is the account,
                    // and a runner that re-read a closed entry's outcome as a reason
                    // to start it again would be the duplicate launch this whole
                    // design exists to prevent.
                    _log.WriteLine($"entry {entry.Ordinal.ToString(CultureInfo.InvariantCulture)} '{entry.EntryId}' already ended '{record.Outcome}'; not started again.");
                    if (!record.EndedComplete)
                    {
                        anyUnsuccessful = true;
                        if (_manifest.Execution.StopsOnFirstFailure)
                        {
                            stopped = true;
                            break;
                        }
                    }
                    continue;
                }

                // A committed launch with no ending refuses rather than guesses.
                // A recorded child that is provably gone falls through to the
                // resume below, where the entry's OWN coordinator decides what is
                // already done.
                journal.RequireResumable(record);

                if (DescribeBudgetStop(journal) is { } exhausted)
                {
                    _log.WriteLine($"stopping before entry {entry.Ordinal.ToString(CultureInfo.InvariantCulture)} '{entry.EntryId}': {exhausted}");
                    PublishIndexSafely(journal, key, CohortIndex.ReasonBudgetExhausted, exhausted);
                    return CoordinatorExitCodes.CohortBudgetExhausted;
                }

                var outcome = RunEntry(journal, key, entry, record);
                PublishIndexSafely(journal, key, CohortIndex.ReasonRunning, "the cohort is in progress");
                if (!string.Equals(outcome, CohortEntryOutcomes.Complete, StringComparison.Ordinal))
                {
                    anyUnsuccessful = true;
                    if (_manifest.Execution.StopsOnFirstFailure)
                    {
                        _log.WriteLine($"stop policy '{_manifest.Execution.StopPolicy}': entry '{entry.EntryId}' ended '{outcome}' and the remaining entries stay pending.");
                        stopped = true;
                        break;
                    }
                }
            }

            if (stopped)
            {
                PublishIndexSafely(
                    journal,
                    key,
                    CohortIndex.ReasonStoppedOnFailure,
                    "an entry ended other than complete and the declared stop policy ends the cohort there");
                return CoordinatorExitCodes.SlotNotComplete;
            }
            if (anyUnsuccessful)
            {
                PublishIndexSafely(
                    journal,
                    key,
                    CohortIndex.ReasonCompletedWithFailure,
                    "every declared entry was reached and at least one ended other than complete");
                return CoordinatorExitCodes.SlotNotComplete;
            }
            PublishIndexSafely(journal, key, CohortIndex.ReasonCompleted, "every declared entry ended complete");
            return CoordinatorExitCodes.Ok;
        }
        catch (CohortBlockedException error)
        {
            PublishIndexOnFault(journal, key, CohortIndex.ReasonBlocked, "the cohort was blocked; the refusal is in the runner log", error.Message);
            throw;
        }
        catch (CohortUnresolvedLaunchException error)
        {
            PublishIndexOnFault(journal, key, CohortIndex.ReasonUnresolvedLaunch, "a committed launch could not be resolved; the refusal is in the runner log", error.Message);
            throw;
        }
        catch (ContractException error)
        {
            PublishIndexOnFault(journal, key, CohortIndex.ReasonContractRefusal, "a declaration was refused; the refusal is in the runner log", error.Message);
            throw;
        }
        catch (Exception error)
        {
            // Deliberately broad, and deliberately rethrowing. The index is the
            // only durable account of what this cohort touched, so it is written
            // even for a fault this class did not anticipate - and then the fault
            // is allowed to travel.
            PublishIndexOnFault(journal, key, CohortIndex.ReasonUnexpectedFault, "the cohort faulted; the fault is in the runner log", error.ToString());
            throw;
        }
    }

    /// <summary>
    /// Verifies one entry's pins, commits the intent, starts the preparation,
    /// waits on it, and accounts for how it ended.
    /// </summary>
    private string RunEntry(CohortJournal journal, byte[] key, CohortEntry entry, CohortEntryRecord record)
    {
        // Every pin is checked before the intent is committed, so an entry whose
        // request drifted, whose subject drifted, or whose rule bundle changed is
        // refused without ever appearing as a launch that has to be accounted for.
        var request = VerifyEntryPins(entry);

        var specification = DescribeLaunch(entry);
        var intentSha256 = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(specification));
        var attempt = record.Attempt + 1;
        if (attempt > CohortJournal.MaximumAttempts)
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' would be attempted {attempt.ToString(CultureInfo.InvariantCulture)} times, and an account carries " +
                $"at most {CohortJournal.MaximumAttempts.ToString(CultureInfo.InvariantCulture)}. An entry interrupted this many times needs " +
                "an operator, not another resume.");
        }
        // Per attempt, never overwritten. An intent is the statement of what this
        // runner was about to start; a second attempt after a resume that
        // overwrote the first would destroy the record of the launch that the
        // resume is trying to account for.
        var intentPath = Path.Combine(
            _manifest.IntentRoot,
            entry.EntryId + ".attempt" + attempt.ToString(CultureInfo.InvariantCulture) + ".intent.json");
        CanonicalJson.WriteFileAtomic(intentPath, CanonicalJson.Readable(specification));

        var intended = record with
        {
            State = CohortEntryStates.LaunchIntended,
            Attempt = attempt,
            IntentSha256 = intentSha256,
            StartedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)
        };
        journal.Commit(
            key,
            intended,
            "launchIntended",
            $"attempt {attempt.ToString(CultureInfo.InvariantCulture)} of entry '{entry.EntryId}' against output root recorded in the manifest");

        _log.WriteLine(
            $"entry {entry.Ordinal.ToString(CultureInfo.InvariantCulture)}/{_manifest.Entries.Count.ToString(CultureInfo.InvariantCulture)} " +
            $"'{entry.EntryId}' attempt {attempt.ToString(CultureInfo.InvariantCulture)} subject={request.CorrelationId}");

        var start = new ProcessStartInfo
        {
            FileName = _manifest.Execution.CommandPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = StrictJson.StrictUtf8,
            StandardErrorEncoding = StrictJson.StrictUtf8,
            WorkingDirectory = _manifest.ToolkitRoot,
            CreateNoWindow = true
        };
        // Forwarded verbatim and never read. Which preparation program runs is the
        // manifest's decision; this runner appends only the two arguments that say
        // WHICH request and HOW FAR, both of which it already verified.
        foreach (var argument in _manifest.Execution.ArgumentPrefix)
        {
            start.ArgumentList.Add(argument);
        }
        start.ArgumentList.Add("--request");
        start.ArgumentList.Add(entry.RequestPath);
        start.ArgumentList.Add("--target");
        start.ArgumentList.Add(_manifest.Execution.Target);

        var stopwatch = Stopwatch.StartNew();
        var standardOut = new StringBuilder();
        var standardError = new StringBuilder();
        Process? process = null;
        var exitCode = -1;
        var outcome = CohortEntryOutcomes.PreparationFaulted;
        var detail = "the entry did not reach an outcome this runner recorded";
        try
        {
            try
            {
                process = Process.Start(start) ?? throw new ContractException($"The preparation for entry '{entry.EntryId}' did not start.");
            }
            catch (Exception error) when (error is not ContractException)
            {
                throw new ContractException(
                    $"The preparation for entry '{entry.EntryId}' could not be started from '{_manifest.Execution.CommandPath}': {error.Message}");
            }

            // The child's exact identity is committed the moment it exists and
            // before anything is waited on. A runner killed from outside cannot
            // clean up after itself, so this record is the only thing that can
            // tell a later run that a preparation of this entry is still alive.
            // Process id alone would not do: process ids are recycled.
            journal.Commit(
                key,
                intended with
                {
                    State = CohortEntryStates.Running,
                    ChildProcessId = process.Id,
                    ChildStartedAtUtc = RecordedStartTime(process)
                },
                "running",
                $"the preparation for entry '{entry.EntryId}' was started and its identity recorded");

            process.OutputDataReceived += (_, args) => { if (args.Data is not null) { lock (standardOut) { standardOut.AppendLine(args.Data); } } };
            process.ErrorDataReceived += (_, args) => { if (args.Data is not null) { lock (standardError) { standardError.AppendLine(args.Data); } } };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.StandardInput.Close();

            if (!process.WaitForExit(_manifest.Execution.EntryTimeoutSeconds * 1000))
            {
                ChildJournal.KillTree(process, DrainMilliseconds);
                // Bounded, deliberately. A kill that could not be delivered leaves
                // a child this run cannot stop, and an unbounded wait here would
                // hand the whole sequential cohort to it forever. What follows in
                // the finally block records that case as abandoned, which is the
                // honest account and the one that refuses to resume the entry.
                // The log builders are read under their own lock, so a reader that
                // is still appending is not a race.
                process.WaitForExit(DrainMilliseconds);
                outcome = CohortEntryOutcomes.TimedOut;
                detail = $"the entry exceeded its {_manifest.Execution.EntryTimeoutSeconds.ToString(CultureInfo.InvariantCulture)} second budget and its tree was killed";
            }
            else
            {
                process.WaitForExit();
                exitCode = process.ExitCode;
                outcome = OutcomeFor(exitCode);
                detail = $"the preparation exited {exitCode.ToString(CultureInfo.InvariantCulture)}";
            }
        }
        finally
        {
            stopwatch.Stop();
            var exited = true;
            if (process is not null)
            {
                if (!process.HasExited)
                {
                    ChildJournal.KillTree(process, DrainMilliseconds);
                }
                exited = process.HasExited;
                process.Dispose();
            }
            WriteLogs(entry, standardOut, standardError);
            if (!exited)
            {
                // A child this run could not prove had exited is recorded as
                // abandoned rather than ended-cleanly, because a later run must
                // never start a second writer of that entry's output root.
                outcome = CohortEntryOutcomes.Abandoned;
                detail += ", and its tree could not be confirmed stopped";
            }
        }

        // Ceiling, not truncation. A run that took a fraction of a second is a run
        // that took time, and a budget that counts seconds must not be handed a
        // zero for it.
        var elapsed = (int)Math.Min(int.MaxValue, Math.Ceiling(Math.Max(0, stopwatch.Elapsed.TotalSeconds)));
        // Read AFTER the child is gone and BEFORE the ending is committed, so the
        // committed account carries the counts the entry actually published rather
        // than counts a later reader would have to go and find.
        CohortEntrySummary summary;
        try
        {
            summary = CohortSummaryReader.Read(entry, intended, elapsed, request.CorrelationId);
            RequireEvidenceAccountedFor(entry, outcome, summary);
        }
        catch (Exception error) when (error is CohortBlockedException or IOException or UnauthorizedAccessException)
        {
            // The refusal stands, but the entry is closed first. An entry left
            // recorded as running once its child is gone is an entry a later run
            // would read as resumable and start a second time - which is the one
            // thing a preview-only cohort must never do, and refusing to read its
            // evidence is no reason to do it. Every way of failing to acquire that
            // evidence gets the same treatment, including the ones that are about
            // the file system rather than the contract: the child is equally gone
            // in all of them.
            var blocked = error as CohortBlockedException;
            journal.Commit(
                key,
                intended with
                {
                    State = CohortEntryStates.Ended,
                    EndedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                    ExitCode = exitCode,
                    Outcome = CohortEntryOutcomes.EvidenceRefused,
                    ElapsedSeconds = elapsed,
                    // Carried out of the refusal rather than defaulted. An entry
                    // closed BECAUSE its audit reported a write must not be summed
                    // into the index as having written nothing.
                    ProviderWriteCount = blocked?.ObservedProviderWriteCount ?? 0,
                    WriteToolInvocationCount = blocked?.ObservedWriteToolInvocationCount ?? 0
                },
                "ended",
                "the entry's published evidence could not be read as this build's, and the entry is closed rather than left open");
            if (blocked is not null)
            {
                throw;
            }
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' published evidence this run could not acquire: {error.Message} " +
                "A cohort index is only worth what the artifacts it indexes are worth, so the whole cohort stops here.");
        }
        var ending = intended with
        {
            State = CohortEntryStates.Ended,
            EndedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
            ExitCode = exitCode,
            Outcome = outcome,
            ElapsedSeconds = elapsed,
            ModelStartCount = summary.ModelStartCount,
            VerifierAssignmentCount = summary.VerifierAssignmentCount,
            SlotLaunchCount = summary.SlotLaunchCount,
            ProviderWriteCount = summary.ProviderWriteCount,
            WriteToolInvocationCount = summary.WriteToolInvocationCount,
            AuditSha256 = summary.AuditSha256
        };
        // Digested against the ENDED record, because that is the record every
        // later reader will hold when it rebuilds this summary. A digest taken
        // over the pre-ending record would name a summary that no rebuild can
        // ever produce, and an unreproducible digest proves nothing.
        var ended = ending with
        {
            SummarySha256 = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical((summary with { Record = ending }).Describe()))
        };
        journal.Commit(key, ended, "ended", detail);
        _log.WriteLine(
            $"entry '{entry.EntryId}' ended {outcome} in {elapsed.ToString(CultureInfo.InvariantCulture)}s " +
            $"modelStarts={summary.ModelStartCount.ToString(CultureInfo.InvariantCulture)} " +
            $"verifierAssignments={summary.VerifierAssignmentCount.ToString(CultureInfo.InvariantCulture)} " +
            $"providerWrites={summary.ProviderWriteCount.ToString(CultureInfo.InvariantCulture)}");
        return outcome;
    }

    /// <summary>
    /// The child's start time as a value the journal can hold.
    /// </summary>
    /// <remarks>
    /// A child that exits between starting and being asked has no readable start
    /// time. Committing the empty string for it would write a record this
    /// journal's own reader refuses, wedging a signed file; committing 'none'
    /// records the fact that liveness cannot later be decided for this child,
    /// which a resume then refuses on rather than guessing.
    /// </remarks>
    private static string RecordedStartTime(Process process)
    {
        var started = ChildJournal.StartedAtUtc(process);
        return started.Length == 0 ? "none" : started;
    }

    /// <summary>
    /// The four endings this runner tells apart, and it tells them apart by exit
    /// code alone.
    /// </summary>
    /// <remarks>
    /// A passthrough, not a judgement. The preparation decides what happened; the
    /// only thing decided here is which of its documented codes means the entry is
    /// done, which means its supervised run ended other than complete, and which
    /// means the preparation itself never got that far.
    /// </remarks>
    private static string OutcomeFor(int exitCode) => exitCode switch
    {
        CoordinatorExitCodes.Ok => CohortEntryOutcomes.Complete,
        CoordinatorExitCodes.SlotNotComplete => CohortEntryOutcomes.RunNotComplete,
        _ => CohortEntryOutcomes.PreparationFaulted
    };

    /// <summary>
    /// Proves the request on disk is the request this cohort authorized, and that
    /// it describes the subject the manifest says it does.
    /// </summary>
    /// <remarks>
    /// Every check is an equality against something sealed in the manifest, and
    /// every failure is a refusal rather than a repair. The order matters only in
    /// that the digest is checked first: a request whose bytes changed is not a
    /// request whose fields are worth comparing.
    /// </remarks>
    private CoordinatorRequest VerifyEntryPins(CohortEntry entry)
    {
        var request = CoordinatorRequest.Load(entry.RequestPath);
        if (!string.Equals(request.RequestSha256, entry.RequestSha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' names a request digesting to {request.RequestSha256} and the manifest sealed {entry.RequestSha256}. " +
                "A request that changed after the cohort was declared is a request nobody authorized.");
        }

        var declared = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(entry.DescribeSubject()));
        var actual = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(request.DescribeSubject()));
        if (!string.Equals(declared, actual, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' declares a subject digesting to {declared} and its request describes {actual}. " +
                "An entry that would prepare a different pull request, iteration or commit than the one authorized is refused.");
        }

        if (!string.Equals(request.ToolkitHead, _manifest.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' pins toolkit head {request.ToolkitHead} and the cohort pins {_manifest.ToolkitHead}. " +
                "One cohort is one reviewed build, so every entry in it is prepared under the same head.");
        }
        if (!string.Equals(request.RequiredRef, _manifest.RequiredRef, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' requires ref '{request.RequiredRef}' and the cohort requires '{_manifest.RequiredRef}'.");
        }

        foreach (var (name, sealedValue, requestValue) in new[]
        {
            ("configSha256", entry.ConfigSha256, request.ConfigSha256),
            ("promptSha256", entry.PromptSha256, request.PromptSha256),
            ("schemaSha256", entry.SchemaSha256, request.SchemaSha256)
        })
        {
            if (!string.Equals(sealedValue, requestValue, StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' seals {name} {sealedValue} and its request carries {requestValue}.");
            }
        }

        // The child is started with its working directory set to the toolkit
        // checkout, so a request declaring a relative output root would be
        // resolved here against THIS process's directory and written by the child
        // into a different one. The parent would then find nothing where the
        // evidence belongs, and an entry with no audit standing in its root is
        // exactly the shape a completed-but-unaccounted entry would take.
        if (!Path.IsPathFullyQualified(request.OutputRoot))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' names a request writing to '{request.OutputRoot}', which is not fully qualified. " +
                "The preparation is started in the toolkit checkout rather than in this directory, so a root that is not fully " +
                "qualified names one place here and another place there.");
        }

        var declaredRoot = CohortManifest.NormalizeRoot(entry.OutputRoot);
        var requestRoot = CohortManifest.NormalizeRoot(request.OutputRoot);
        if (!string.Equals(declaredRoot, requestRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' declares output root '{declaredRoot}' and its request writes to '{requestRoot}'. " +
                "The root a cohort indexes must be the root the preparation writes, or the index would name evidence nobody produced.");
        }

        // The rule bundle is bound by digest rather than described. What the rules
        // ARE is the reviewed side's business and nothing here reads them; what is
        // checked is that the bundle the operator declared is the bundle on disk.
        if (!File.Exists(entry.RuleBundlePath))
        {
            throw new ContractException($"Entry '{entry.EntryId}' declares a rule bundle at '{entry.RuleBundlePath}', and there is no such file.");
        }
        var bundleDigest = CanonicalJson.Sha256Hex(StrictJson.ReadFileBytes(entry.RuleBundlePath, $"entry '{entry.EntryId}' rule bundle", 8L * 1024 * 1024));
        if (!string.Equals(bundleDigest, entry.RuleBundleSha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"Entry '{entry.EntryId}' declares a rule bundle digesting to {entry.RuleBundleSha256} and the file at " +
                $"'{entry.RuleBundlePath}' digests to {bundleDigest}.");
        }

        // The whole point of the cohort is to scale the FULL typed pipeline, and
        // the full pipeline is the one that supervises two slots, reconciles them
        // and evaluates one preview-only decision. An entry declaring less than
        // that is refused here rather than silently indexed as though it had run
        // the same pipeline as its neighbours.
        var slots = request.RequireSlotSet();
        var delivery = slots.RequireDelivery();
        if (!string.Equals(delivery.AuthorizationKind, CohortExecution.PreviewOnlyKind, StringComparison.Ordinal)
            || delivery.ProviderWriteBudget != 0)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' declares a delivery this cohort cannot authorize. A cohort runs preview-only with a zero write budget, " +
                "and it abandons every remaining entry rather than start one that declared otherwise.");
        }
        return request;
    }

    /// <summary>
    /// The live head of the toolkit this cohort was declared against, or a
    /// refusal.
    /// </summary>
    /// <remarks>
    /// Asked once, at the top, rather than per entry. A checkout that moved under
    /// a cohort invalidates every entry in it equally - the entries were declared
    /// against one reviewed build - and discovering that at entry four would mean
    /// three preparations already stand on a head the manifest no longer
    /// describes.
    /// </remarks>
    private void RequireLiveToolkitHead()
    {
        var head = GitHead.Resolve(_manifest.ToolkitRoot);
        if (!string.Equals(head, _manifest.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The cohort pins toolkit head {_manifest.ToolkitHead} and '{_manifest.ToolkitRoot}' is at {head}. " +
                "A cohort is one reviewed build prepared across several subjects; a checkout that moved is a different build.");
        }
    }

    /// <summary>
    /// Names the global ceiling the next entry would cross, or null when it fits.
    /// </summary>
    /// <remarks>
    /// The estimates are the manifest's, sealed with it; the actuals are read out
    /// of the signed journal, from entries that have ALREADY ended. Nothing in
    /// flight contributes, because a total that moves while it is being compared
    /// is not a ceiling.
    ///
    /// A crossing is a hard stop, not a truncation of the entry: the remaining
    /// entries stay pending, which is what lets an operator raise a ceiling in a
    /// new manifest and finish the set rather than lose it.
    /// </remarks>
    private string? DescribeBudgetStop(CohortJournal journal)
    {
        long models = 0;
        long verifiers = 0;
        long seconds = 0;
        var started = 0;
        foreach (var declared in _manifest.Entries)
        {
            var record = journal.RecordFor(declared.EntryId);
            if (!record.HasEnded)
            {
                continue;
            }
            models += record.ModelStartCount;
            verifiers += record.VerifierAssignmentCount;
            seconds += record.ElapsedSeconds;
            started++;
        }

        if (started + 1 > _manifest.Budgets.MaximumPullRequests)
        {
            return Exhausted("pull request", started, 1, _manifest.Budgets.MaximumPullRequests);
        }
        // The next entry's own sealed estimate is what is admitted against the
        // remaining ceiling. Admitting an entry on the strength of what previous
        // entries happened to cost would be admitting it on a guess.
        var next = NextPendingEntry(journal);
        if (next is null)
        {
            return null;
        }
        if (models + next.EstimatedModelStarts > _manifest.Budgets.MaximumModelStarts)
        {
            return Exhausted("model start", models, next.EstimatedModelStarts, _manifest.Budgets.MaximumModelStarts);
        }
        if (verifiers + next.EstimatedVerifierAssignments > _manifest.Budgets.MaximumVerifierAssignments)
        {
            return Exhausted("verifier assignment", verifiers, next.EstimatedVerifierAssignments, _manifest.Budgets.MaximumVerifierAssignments);
        }
        if (seconds + next.EstimatedWallClockSeconds > _manifest.Budgets.MaximumWallClockSeconds)
        {
            return Exhausted("wall clock second", seconds, next.EstimatedWallClockSeconds, _manifest.Budgets.MaximumWallClockSeconds);
        }
        return null;
    }

    private CohortEntry? NextPendingEntry(CohortJournal journal)
    {
        foreach (var declared in _manifest.Entries)
        {
            if (!journal.RecordFor(declared.EntryId).HasEnded)
            {
                return declared;
            }
        }
        return null;
    }

    private static string Exhausted(string unit, long consumed, long estimated, int ceiling) =>
        $"the cohort has consumed {consumed.ToString(CultureInfo.InvariantCulture)} {unit}(s), the next entry is sealed at " +
        $"{estimated.ToString(CultureInfo.InvariantCulture)}, and the ceiling is {ceiling.ToString(CultureInfo.InvariantCulture)}. " +
        "The remaining entries stay pending and nothing is truncated.";

    /// <summary>
    /// The exact launch this runner committed an intent for, as a record a killed
    /// runner leaves behind.
    /// </summary>
    private MapNode DescribeLaunch(CohortEntry entry)
    {
        var arguments = new ListNode();
        foreach (var argument in _manifest.Execution.ArgumentPrefix)
        {
            arguments.Add(argument);
        }
        arguments.Add("--request");
        arguments.Add(entry.RequestPath);
        arguments.Add("--target");
        arguments.Add(_manifest.Execution.Target);
        return new MapNode()
            .Set("contractVersion", "devpilot.shadow-cohort.launch-intent.v1")
            .Set("cohortId", _manifest.CohortId)
            .Set("manifestSha256", _manifest.ManifestSha256)
            .Set("entryId", entry.EntryId)
            .Set("ordinal", entry.Ordinal)
            .Set("subjectSha256", entry.SubjectSha256)
            .Set("requestSha256", entry.RequestSha256)
            .Set("outputRoot", CohortManifest.NormalizeRoot(entry.OutputRoot))
            .Set("commandPath", _manifest.Execution.CommandPath)
            .Set("arguments", arguments)
            .Set("authorizedBy", _operatorAlias)
            .Set("plannedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
    }

    private void WriteLogs(CohortEntry entry, StringBuilder standardOut, StringBuilder standardError)
    {
        // Captured for a human and never parsed: a diagnostic line from a
        // well-meaning helper cannot become part of an account. What this runner
        // reads is the exit code and the published audit, both of which are
        // contracts.
        try
        {
            lock (standardOut)
            {
                File.WriteAllText(Path.Combine(_manifest.LogRoot, entry.EntryId + ".out.log"), standardOut.ToString(), StrictJson.StrictUtf8);
            }
            lock (standardError)
            {
                File.WriteAllText(Path.Combine(_manifest.LogRoot, entry.EntryId + ".err.log"), standardError.ToString(), StrictJson.StrictUtf8);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.WriteLine($"entry '{entry.EntryId}' logs not written: {error.Message}");
        }
    }

    /// <summary>
    /// Refuses a launched preparation with nothing standing where its evidence
    /// belongs, whatever it says about how it ended.
    /// </summary>
    /// <remarks>
    /// A preparation that exits cleanly has published its audit; that is what
    /// exiting cleanly means here. An entry that reports completion with no audit
    /// in its output root would otherwise be summarized as a preparation that ran
    /// and consumed nothing - a completed entry with no evidence, no model starts
    /// and no write counters, which is indistinguishable in the index from a
    /// cohort that genuinely cost nothing.
    ///
    /// A preparation that crashed, hung or was killed is no better off. It was
    /// launched, so it may have started models and it may have had a provider act
    /// on its behalf; nothing it left behind says either way. Carrying it into the
    /// index would publish a zero write count for an entry that never proved one,
    /// and the zero-write claim is the whole point of a preview-only cohort. The
    /// admission arithmetic is in the same position: what it consumed is not a
    /// number this runner can state, and a ceiling computed over an unknown is not
    /// a ceiling. So every launched entry with no readable evidence stops the
    /// cohort, whatever the stop policy says, and the walk keeps it stopped: a
    /// resume over a refused entry refuses again, because nothing about that
    /// output root has been settled by running the cohort a second time.
    ///
    /// This reads the summary rather than the file system so that there is one
    /// decision and not two. A separate existence check before the read would be
    /// answering a question the read then asks again, and an audit removed between
    /// the two answers would pass the first and be summarized away by the second.
    /// </remarks>
    private static void RequireEvidenceAccountedFor(CohortEntry entry, string outcome, CohortEntrySummary summary)
    {
        if (!string.Equals(summary.AuditSha256, "none", StringComparison.Ordinal))
        {
            return;
        }
        throw new CohortBlockedException(
            $"Entry '{entry.EntryId}' ended '{outcome}' and published no audit at " +
            $"'{CohortSummaryReader.AuditPathFor(entry)}'. A launched preparation with no evidence behind it cannot be counted " +
            "against this cohort's ceiling, and it cannot support the claim that nothing was written, so the cohort stops rather " +
            "than indexing it as a preparation that cost nothing.");
    }

    /// <summary>Writes the index and refuses to let a failure to write it end the cohort.</summary>
    /// <remarks>
    /// The signed journal is authoritative; the index is a report derived from it.
    /// If the report cannot be written the cohort has still done what the journal
    /// says it did, and the next run over this root rewrites the index from the
    /// journal without starting anything. The word itself is committed outside
    /// that leniency, because a cohort that could not write down what it published
    /// has not published it: swallowing a failed journal replacement here would
    /// let a cohort exit successfully while its record still said something else,
    /// and every later rebuild would report that something else.
    /// </remarks>
    private void PublishIndexSafely(CohortJournal journal, byte[] key, string reason, string detail, string? spokenDetail = null)
    {
        var terminalDetailSha256 = CanonicalJson.Sha256HexOfText(spokenDetail ?? detail);
        journal.RecordTerminal(key, reason, detail, terminalDetailSha256);
        try
        {
            PublishIndexCore(journal, key, reason, detail, terminalDetailSha256, recordTerminal: false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.WriteLine(
                $"cohort index not written ({reason}): {error.Message}. " +
                "The journal is authoritative and the next run over this root rewrites the index from it.");
        }
    }

    /// <summary>
    /// Writes the index while a refusal is already travelling.
    /// </summary>
    /// <remarks>
    /// The refusal that got here is the one worth reporting, so a second refusal
    /// raised while accounting for the first is logged and swallowed rather than
    /// allowed to replace it. Everywhere else a refusal from the publish is a
    /// refusal, because everywhere else there is nothing it would be hiding.
    /// </remarks>
    private void PublishIndexOnFault(CohortJournal journal, byte[] key, string reason, string detail, string spokenDetail)
    {
        _log.WriteLine($"cohort stopping ({reason}): {spokenDetail}");
        try
        {
            PublishIndex(journal, key, reason, detail, spokenDetail);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ContractException or CohortBlockedException)
        {
            _log.WriteLine(
                $"cohort index not written ({reason}): {error.Message}. " +
                "The journal is authoritative and the refusal above is the one that matters.");
        }
    }

    /// <summary>
    /// Rebuilds every summary from the per-entry audits and publishes the index.
    /// </summary>
    /// <remarks>
    /// The summaries are re-derived here rather than copied out of the journal,
    /// which is what makes the index rebuildable at all. That only means anything
    /// if the re-derivation is checked against what was committed at the time, so
    /// an ended entry's recomputed audit and summary digests must equal the ones
    /// its ending recorded. A published audit that was removed, replaced or edited
    /// after the fact is refused here rather than quietly re-signed into a new
    /// index that disagrees with the journal.
    /// </remarks>
    private void PublishIndex(CohortJournal journal, byte[] key, string reason, string detail, string? spokenDetail = null) =>
        PublishIndexCore(journal, key, reason, detail, CanonicalJson.Sha256HexOfText(spokenDetail ?? detail), recordTerminal: true);

    /// <summary>
    /// Commits the word being published and then writes the index that carries
    /// it.
    /// </summary>
    /// <remarks>
    /// The journal is written first and the index second, so a runner killed
    /// between them leaves a signed record that already says what the missing
    /// index would have said, and a rebuild reproduces it exactly. A rebuild
    /// itself records nothing: it reports.
    /// </remarks>
    private void PublishIndexCore(
        CohortJournal journal,
        byte[] key,
        string reason,
        string detail,
        string terminalDetailSha256,
        bool recordTerminal)
    {
        if (recordTerminal)
        {
            journal.RecordTerminal(key, reason, detail, terminalDetailSha256);
        }
        var summaries = new List<CohortEntrySummary>(_manifest.Entries.Count);
        foreach (var entry in _manifest.Entries)
        {
            var record = journal.RecordFor(entry.EntryId);
            if (!record.HasEnded || record.EndedRefused)
            {
                // A refused entry is summarized as a shape, not as readings. Its
                // audit is the artifact this build could not read as its own, so
                // re-reading it here would only reproduce the refusal - and the
                // index that has to carry the news of that refusal is the very
                // thing being written.
                summaries.Add(CohortEntrySummary.NotRun(entry, record));
                continue;
            }
            var summary = CohortSummaryReader.Read(entry, record, record.ElapsedSeconds, CorrelationOf(entry));
            RequireCommittedDigests(entry, record, summary);
            summaries.Add(summary);
        }
        CohortIndex.Publish(
            _manifest,
            journal,
            key,
            summaries,
            reason,
            detail,
            terminalDetailSha256);
    }

    /// <summary>
    /// The correlation the entry's own request declares, which is what an audit
    /// found in that entry's output root has to agree with.
    /// </summary>
    private string CorrelationOf(CohortEntry entry)
    {
        if (_correlations.TryGetValue(entry.EntryId, out var known))
        {
            return known;
        }
        var correlation = CoordinatorRequest.Load(entry.RequestPath).CorrelationId;
        _correlations[entry.EntryId] = correlation;
        return correlation;
    }

    private static void RequireCommittedDigests(CohortEntry entry, CohortEntryRecord record, CohortEntrySummary summary)
    {
        if (!string.Equals(record.AuditSha256, summary.AuditSha256, StringComparison.Ordinal))
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' ended against an audit digesting to {record.AuditSha256}, and the audit standing in its output " +
                $"root now digests to {summary.AuditSha256}. The index claims to be rebuildable from the artifacts it names; an artifact " +
                "that changed after it was accounted for makes that claim false, so the cohort stops rather than re-sign a different one.");
        }
        var recomputed = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(summary.Describe()));
        if (!string.Equals(record.SummarySha256, recomputed, StringComparison.Ordinal))
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' committed summary {record.SummarySha256} and the same artifacts now summarize to {recomputed}. " +
                "A summary that cannot be reproduced from what it was taken over is not evidence of anything.");
        }
    }
}

/// <summary>
/// One cohort runner per journal root, decided from files rather than from a
/// process list.
/// </summary>
/// <remarks>
/// The same reasoning as the single-run lease, and for the same reason: the hard
/// part is deciding whether a lease left behind by a killed process is still
/// live. The holder's identifier AND its exact start time are recorded, and a
/// holder counts as live only when both agree, so a recycled identifier is
/// correctly treated as an abandoned lease rather than as a live runner.
///
/// It deliberately does NOT reason about entry children: an entry whose
/// preparation is still alive is the journal's business, and refusing there is
/// what lets a resumed runner walk past entries that already ended.
/// </remarks>
internal sealed class CohortLease : IDisposable
{
    private const string ContractVersionValue = "devpilot.shadow-cohort.lease.v1";

    private readonly string _path;
    private FileStream? _handle;
    private bool _released;

    private CohortLease(string path, FileStream handle)
    {
        _path = path;
        _handle = handle;
    }

    internal static CohortLease Acquire(CohortManifest manifest)
    {
        Directory.CreateDirectory(manifest.JournalRoot);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                var handle = new FileStream(manifest.LeasePath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
                try
                {
                    var current = Process.GetCurrentProcess();
                    var record = new MapNode()
                        .Set("contractVersion", ContractVersionValue)
                        .Set("cohortId", manifest.CohortId)
                        .Set("processId", current.Id)
                        .Set("processStartedAtUtc", current.StartTime.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture))
                        .Set("acquiredAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
                    var bytes = StrictJson.StrictUtf8.GetBytes(CanonicalJson.Readable(record));
                    handle.Write(bytes, 0, bytes.Length);
                    handle.Flush(flushToDisk: true);
                }
                catch
                {
                    handle.Dispose();
                    File.Delete(manifest.LeasePath);
                    throw;
                }
                return new CohortLease(manifest.LeasePath, handle);
            }
            catch (IOException) when (File.Exists(manifest.LeasePath))
            {
                var holder = ReadHolder(manifest.LeasePath);
                if (holder is not null && IsHolderLive(holder.Value.ProcessId, holder.Value.StartedAtUtc))
                {
                    throw new LeaseConflictException(
                        $"Process {holder.Value.ProcessId.ToString(CultureInfo.InvariantCulture)} already holds the cohort lease at '{manifest.LeasePath}'.");
                }
                if (holder is null && IsWithinPublishGrace(manifest.LeasePath))
                {
                    // Created moments ago and carrying no readable holder record:
                    // overwhelmingly the winner of the CreateNew race in the
                    // instant between creating the lease and flushing its record,
                    // not an abandoned one. Stealing it here would put two runners
                    // on one journal root.
                    throw new LeaseConflictException(
                        $"The cohort lease at '{manifest.LeasePath}' was created within the last {PublishGraceSeconds.ToString(CultureInfo.InvariantCulture)} second(s) " +
                        "and has not published its holder record yet; it is treated as live rather than stolen.");
                }
                try
                {
                    File.Delete(manifest.LeasePath);
                }
                catch (IOException)
                {
                    throw new LeaseConflictException($"The cohort lease at '{manifest.LeasePath}' is held open by another process.");
                }
                catch (UnauthorizedAccessException)
                {
                    throw new LeaseConflictException($"The cohort lease at '{manifest.LeasePath}' cannot be removed by this user.");
                }
            }
        }
        throw new LeaseConflictException($"The cohort lease at '{manifest.LeasePath}' was taken by another process.");
    }

    private const int PublishGraceSeconds = 30;

    private static bool IsWithinPublishGrace(string path)
    {
        try
        {
            var info = new FileInfo(path);
            var stamped = info.CreationTimeUtc > info.LastWriteTimeUtc ? info.CreationTimeUtc : info.LastWriteTimeUtc;
            var age = DateTime.UtcNow - stamped;
            return age >= TimeSpan.Zero && age < TimeSpan.FromSeconds(PublishGraceSeconds);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static (int ProcessId, DateTime StartedAtUtc)? ReadHolder(string path)
    {
        try
        {
            const string label = "cohort lease";
            var root = StrictJson.ReadObjectFile(path, label, maximumBytes: 64 * 1024);
            var processId = StrictJson.RequireInt(root, "processId", label, 1, int.MaxValue);
            var startedText = StrictJson.RequireString(root, "processStartedAtUtc", label);
            if (!DateTime.TryParse(startedText, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var started))
            {
                return null;
            }
            return (processId, started.ToUniversalTime());
        }
        catch (Exception error) when (error is ContractException or FormatException or IOException)
        {
            return null;
        }
    }

    private static bool IsHolderLive(int processId, DateTime startedAtUtc)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            if (process.HasExited)
            {
                return false;
            }
            return Math.Abs((process.StartTime.ToUniversalTime() - startedAtUtc).TotalSeconds) < 1.0;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException)
        {
            return false;
        }
        // A holder this user cannot inspect is deliberately NOT treated as dead:
        // stealing a lease from a process we cannot see is the one direction where
        // being wrong runs two cohorts at once.
        catch (System.ComponentModel.Win32Exception)
        {
            return true;
        }
    }

    public void Dispose()
    {
        if (_released)
        {
            return;
        }
        _released = true;
        _handle?.Dispose();
        _handle = null;
        try
        {
            File.Delete(_path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }
}
