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

    /// <summary>
    /// The registry revision this walk stands on, once it has been authenticated.
    /// </summary>
    /// <remarks>
    /// Held rather than re-read per entry so that the revision an entry records
    /// against is the revision the pre-walk accepted, not whatever is on disk by
    /// then. A second writer that moved the file underneath is caught by the
    /// atomic write's own revision chain rather than silently merged into.
    /// </remarks>
    private CohortRegistry? _registry;

    /// <summary>The key the accepted registry is signed with, read once beside it.</summary>
    private byte[]? _registryKey;

    /// <summary>How long a killed entry tree is given to go before the runner stops waiting on it.</summary>
    private const int DrainMilliseconds = 30_000;

    /// <summary>
    /// The artifact this build accepts as proof of an entry's worst-case real
    /// model consumption, produced by tools/New-ShadowModelStartBound.ps1.
    /// </summary>
    internal const string ModelStartBoundKind = "devpilot.shadow-cohort.model-start-bound.v2";

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
            if (!CountsAsComplete(entry, record))
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
            try
            {
                PublishIndexSafely(journal, key, CohortIndex.ReasonRunning, "the cohort is in progress");
                RequireLiveToolkitHead();
                RequireSealedModelStartBounds();
                RequireDeclaredLaunchAuthorizations();
                RequireRegistryAdmissible(journal, key);
            }
            catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
            {
                // Everything above runs BEFORE the walk reaches the first entry, and
                // every one of these can refuse a resume: damaged artifacts from
                // an entry that already ended, a toolkit checkout that moved, a plan
                // whose bounds no longer read, a declared launch authorization that
                // is no longer the one its run set was sealed against, or an account
                // that took one of this cohort's remaining subjects while it was
                // stopped. An entry that
                // ended and never reached the account would be stranded by any of
                // them - spent, unheld, and free for the next selection - because the
                // row is written by the walk below, which is never reached. So the
                // subjects go on record first, best effort and without adopting
                // anything, and the refusal still stops the run.
                //
                // A checkout that moved is the ordinary trigger, not the exotic one:
                // the window between an entry's ending and its row is one kill, and
                // the operator who comes back to a stopped cohort is the same person
                // who pulls before resuming it.
                HoldSpentSubjectsBeforeFailing(journal);
                throw;
            }

            var stopped = false;
            var anyUnsuccessful = false;
            foreach (var entry in _manifest.Entries)
            {
                var record = journal.RecordFor(entry.EntryId);

                if (record.EndedRefused)
                {
                    // The subject is held first, then the cohort stops. The refusal
                    // is committed; if this throw escaped before the row was written,
                    // a resume would find a closed entry it cannot summarize and a
                    // pull request that had been put in front of the models with
                    // nothing on record - free to be selected again. Idempotent: the
                    // row keys on the refused ending, so recording it on every resume
                    // lands on the same bytes.
                    RecordUnreadableEntrySample(journal, key, entry, record);
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
                    // The ending is committed before the sample is recorded, so a
                    // runner killed between the two leaves a spent subject with no
                    // row. Re-derived here from the same signed evidence rather than
                    // left out: an account missing a spend is the one failure that
                    // lets the next cohort spend it again.
                    RecordEndedEntrySample(journal, key, entry, record);
                    if (!CountsAsComplete(entry, record))
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

                // What has already been spent, before what the next entry would
                // cost. An entry that turned out to cost more than the whole
                // cohort was allowed ends it here: its own result stands and is
                // never re-run, and nothing further launches.
                if (DescribeOverspend(journal) is { } already)
                {
                    _log.WriteLine($"stopping before entry {entry.Ordinal.ToString(CultureInfo.InvariantCulture)} '{entry.EntryId}': {already}");
                    PublishIndexSafely(journal, key, CohortIndex.ReasonBudgetExceeded, already);
                    return CoordinatorExitCodes.CohortBudgetExhausted;
                }

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

            if (DescribeOverspend(journal) is { } overspent)
            {
                // Reached when every entry has ended: the cohort spent more than
                // it was allowed and says so, rather than reporting a clean
                // completion that would hide the overspend behind a green result.
                _log.WriteLine($"cohort budget exceeded: {overspent}");
                PublishIndexSafely(journal, key, CohortIndex.ReasonBudgetExceeded, overspent);
                return CoordinatorExitCodes.CohortBudgetExhausted;
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
        RequireSubjectStillFree(journal, entry);

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
            var refused = intended with
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
            };
            journal.Commit(
                key,
                refused,
                "ended",
                "the entry's published evidence could not be read as this build's, and the entry is closed rather than left open");
            // The subject was spent whatever the evidence says. This entry only got
            // here by running its preparation, so the pull request really was put in
            // front of it, and an account that recorded nothing would offer the same
            // pull request again as a fresh subject. The row is composed from the
            // journal alone - the one thing still readable - and can never count.
            RecordUnreadableEntrySample(journal, key, entry, refused);
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
            ModelStartUnmeasuredAllowance = summary.ModelStartUnmeasuredAllowance,
            VerifierAssignmentCount = summary.VerifierAssignmentCount,
            VerifierAssignmentUnmeasuredAllowance = summary.VerifierAssignmentUnmeasuredAllowance,
            SlotLaunchCount = summary.SlotLaunchCount,
            ProviderWriteCount = summary.ProviderWriteCount,
            WriteToolInvocationCount = summary.WriteToolInvocationCount,
            AuditSha256 = summary.AuditSha256
        };

        // The exit code is not the only witness to whether the entry finished.
        // A preparation told to stop at the cohort's target and stopping there
        // exits non-zero to say it stopped on purpose, and reading that alone as
        // a fault abandons an entry whose signed evidence says it arrived. The
        // adoption is evaluated against the ending as it will be committed, so
        // the decision a later rebuild makes is the decision made here.
        if (!string.Equals(outcome, CohortEntryOutcomes.Complete, StringComparison.Ordinal))
        {
            var (adopted, why) = CohortCompletionAdoption.Evaluate(_manifest, summary with { Record = ending });
            if (adopted)
            {
                _log.WriteLine(
                    $"entry '{entry.EntryId}' exited {exitCode.ToString(CultureInfo.InvariantCulture)} and is adopted complete: {why}");
                outcome = CohortEntryOutcomes.Complete;
                detail = $"the entry exited {exitCode.ToString(CultureInfo.InvariantCulture)} and its authenticated audit proves the cohort's target was reached, so it is accounted complete";
                ending = ending with { Outcome = outcome };
            }
        }

        // Digested against the ENDED record, because that is the record every
        // later reader will hold when it rebuilds this summary. A digest taken
        // over the pre-ending record would name a summary that no rebuild can
        // ever produce, and an unreproducible digest proves nothing.
        var ended = ending with
        {
            SummarySha256 = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical((summary with { Record = ending }).Describe()))
        };
        journal.Commit(key, ended, "ended", detail);
        RecordRegistrySample(journal, key, entry, summary with { Record = ended }, outcome, _operatorAlias);
        _log.WriteLine(
            $"entry '{entry.EntryId}' ended {outcome} in {elapsed.ToString(CultureInfo.InvariantCulture)}s " +
            $"modelStarts={summary.ModelStartCount.ToString(CultureInfo.InvariantCulture)} " +
            $"(generalist={summary.ModelStartsGeneralist.ToString(CultureInfo.InvariantCulture)} " +
            $"specialist={summary.ModelStartsSpecialist.ToString(CultureInfo.InvariantCulture)} " +
            $"verifier={summary.ModelStartsVerifier.ToString(CultureInfo.InvariantCulture)}) " +
            $"verifierAssignments={summary.VerifierAssignmentCount.ToString(CultureInfo.InvariantCulture)} " +
            $"(verifierProcesses={summary.VerifierProcessStartCount.ToString(CultureInfo.InvariantCulture)}) " +
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

        RequireArgumentsAdmissible(entry);
        RequireTargetCompatible(entry, request);
        return request;
    }

    /// <summary>
    /// Refuses to launch a preparation under arguments a live cohort may not pass.
    /// </summary>
    /// <remarks>
    /// This is checked here, on the launch path, rather than when the manifest was
    /// read. Reading is not running: a frozen root has to stay parseable so its
    /// evidence can be re-derived by <c>--rebuild-index</c>, and a root written
    /// under a fault argument is exactly the root whose evidence most needs
    /// re-deriving. What the refusal protects is the launch.
    ///
    /// A cohort that declares the test-only kind may pass them, and pays for the
    /// permission by not being allowed to start the shipping preparation: its
    /// command and arguments may not name this program, and must name a stub.
    ///
    /// The production kind is held to the mirror image. Filtering the arguments
    /// alone would leave a cohort free to name any executable at all and let that
    /// executable decide what it starts, so the fault switches would be refused on
    /// the manifest and reintroduced one process later by a wrapper. A production
    /// cohort therefore has to name this program, directly, and may not name a
    /// stub adapter alongside it. What remains outside the check is an operator
    /// who renamed a binary on their own disk, which is not a boundary a manifest
    /// reader can hold.
    /// </remarks>
    private void RequireArgumentsAdmissible(CohortEntry entry)
    {
        if (!_manifest.IsTestOnly)
        {
            if (_manifest.Execution.RefusedArguments.Count > 0)
            {
                throw new CohortBlockedException(
                    $"The cohort forwards {string.Join("; ", _manifest.Execution.RefusedArguments)}. A cohort declared '{CohortManifest.KindValue}' " +
                    "prepares live pull requests, and a preparation stopped short of its target leaves partial evidence carrying a non-zero exit - " +
                    "the same shape a completed entry would otherwise be read as. Every remaining entry is abandoned rather than started this way.");
            }
            if (!_manifest.Execution.IsShippingLaunchProfile)
            {
                throw new CohortBlockedException(
                    $"The cohort is declared '{CohortManifest.KindValue}' and its launch for entry '{entry.EntryId}' is not one this build starts. " +
                    "A production launch is either the coordinator itself or the dotnet host with the coordinator's assembly first, so that the " +
                    "next thing to read an argument is the coordinator's own parser. Anything interposed - a shell, a wrapper, a script - splits " +
                    "its own arguments one process later, where the switches this kind refuses cannot be seen. Name the coordinator directly.");
            }
            if (_manifest.Execution.NamesStubAdapter)
            {
                throw new CohortBlockedException(
                    $"The cohort is declared '{CohortManifest.KindValue}' and its launch for entry '{entry.EntryId}' names a script. " +
                    "A production launch is the preparation and its own arguments; anything interposed decides for itself what it " +
                    "starts and under which arguments.");
            }
            return;
        }

        if (_manifest.Execution.NamesShippingPreparation)
        {
            throw new CohortBlockedException(
                $"The cohort is declared '{CohortManifest.TestOnlyKindValue}' and its launch for entry '{entry.EntryId}' names this program. " +
                "That kind exists so a fault can be injected, and it is only safe while it cannot reach the preparation that launches a " +
                "reviewer. A cohort that can inject faults into the shipping preparation is neither a test nor a run.");
        }
        if (!_manifest.Execution.NamesStubAdapter)
        {
            throw new CohortBlockedException(
                $"The cohort is declared '{CohortManifest.TestOnlyKindValue}' and its launch for entry '{entry.EntryId}' names no stub adapter. " +
                "The permission to inject faults is paid for by starting a stub, and a launch that cannot be shown to start one is refused " +
                "rather than assumed harmless.");
        }
    }

    /// <summary>
    /// Refuses to launch an entry whose reviewer configuration was written for a
    /// different branch than the one the pull request actually merges into.
    /// </summary>
    /// <remarks>
    /// A pull request targeting a release branch reviewed under a configuration
    /// bound to the trunk is not a review of that pull request. The mismatch does
    /// not announce itself: the preparation gets far enough to fetch and to
    /// reconcile before anything notices the branch it was told about is not the
    /// branch the change lands on, by which point models may already have run.
    ///
    /// So the comparison happens here, before the intent is committed and before
    /// any child exists. The configuration is read through the digest the request
    /// already sealed, so a configuration edited after the cohort was declared is
    /// refused as a digest mismatch rather than compared as though it were the
    /// authorized one.
    /// </remarks>
    private void RequireTargetCompatible(CohortEntry entry, CoordinatorRequest request)
    {
        if (entry.TargetRefName.Length == 0)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' pins no subject targetRefName. An entry is launched only once the branch it merges into has been " +
                "compared with the branch its reviewer configuration was written for, and an unpinned target cannot be compared. Re-declare " +
                "the cohort with the target this pull request actually merges into.");
        }

        var configPath = request.ReviewerConfigPath;
        byte[] bytes;
        try
        {
            bytes = StrictJson.ReadFileBytes(configPath, $"entry '{entry.EntryId}' reviewer configuration", 8L * 1024 * 1024);
        }
        catch (ContractException error)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' names a reviewer configuration at '{configPath}' that could not be read ({error.Message}). " +
                "A configuration that cannot be read cannot be proven to describe the branch this pull request merges into.");
        }
        catch (Exception error)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' names a reviewer configuration at '{configPath}' that could not be read ({error.GetType().Name}). " +
                "A configuration that cannot be read cannot be proven to describe the branch this pull request merges into.");
        }

        var configDigest = CanonicalJson.Sha256Hex(bytes);
        if (!string.Equals(configDigest, entry.ConfigSha256, StringComparison.Ordinal))
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' seals a reviewer configuration digesting to {entry.ConfigSha256} and '{configPath}' digests to " +
                $"{configDigest}. The configuration whose target is compared has to be the configuration the cohort authorized.");
        }

        string configured;
        try
        {
            var root = StrictJson.ReadObjectBytes(bytes, configPath, $"entry '{entry.EntryId}' reviewer configuration");
            var review = StrictJson.RequireObject(root, "review", $"entry '{entry.EntryId}' reviewer configuration");
            configured = StrictJson.RequireString(review, "targetRefName", $"entry '{entry.EntryId}' reviewer configuration review");
        }
        catch (ContractException error)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' names a reviewer configuration at '{configPath}' that declares no readable review.targetRefName " +
                $"({error.Message}). An entry whose configuration does not say which branch it reviews against is not launched.");
        }

        if (!string.Equals(configured, entry.TargetRefName, StringComparison.Ordinal))
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' merges into '{entry.TargetRefName}' and its reviewer configuration reviews against '{configured}'. " +
                "A pull request targeting one branch reviewed under a configuration bound to another is not a review of that pull request, so " +
                "the cohort is abandoned rather than the entry started. Bind a configuration to the branch this pull request actually targets. " +
                "The comparison is exact: a differently-cased ref names a different branch to the provider that resolves it.");
        }
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
    /// Proves, before anything launches, that every entry's declared model-start
    /// estimate is an upper bound on the real model subprocess starts its sealed
    /// plan could produce.
    /// </summary>
    /// <remarks>
    /// The bound itself is derived on the reviewed side, where what a slot
    /// argument vector means is already understood, and sealed into an artifact
    /// bound to the exact request bytes. This build only checks the seals: the
    /// artifact digests to what the manifest declared, it was taken over THIS
    /// entry's request and toolkit head, and the estimate the manifest carries is
    /// not below the bound the artifact publishes.
    ///
    /// Refusal is the only outcome for a missing, unreadable or mismatched bound.
    /// An estimate with nothing behind it is what let a cohort declare a ceiling
    /// of three for a run that really started four models, and a budget that can
    /// be under-declared is not a budget.
    /// </remarks>
    private void RequireSealedModelStartBounds()
    {
        long bounded = 0;
        long boundedAssignments = 0;
        foreach (var entry in _manifest.Entries)
        {
            var label = $"entry '{entry.EntryId}' model start bound";
            if (!File.Exists(entry.ModelStartBoundPath))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' declares a model start bound at '{entry.ModelStartBoundPath}', and there is no such file. " +
                    "A cohort does not launch a preparation whose worst-case model consumption nobody proved.");
            }
            var bytes = StrictJson.ReadFileBytes(entry.ModelStartBoundPath, label, 4L * 1024 * 1024);
            var digest = CanonicalJson.Sha256Hex(bytes);
            if (!string.Equals(digest, entry.ModelStartBoundSha256, StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' seals a model start bound digesting to {entry.ModelStartBoundSha256} and the file at " +
                    $"'{entry.ModelStartBoundPath}' digests to {digest}. A bound that changed after the cohort was declared is not the bound that was authorized.");
            }

            var root = StrictJson.ReadObjectBytes(bytes, entry.ModelStartBoundPath, label);
            StrictJson.RequireLiteral(root, "kind", ModelStartBoundKind, label);
            var boundRequest = StrictJson.RequireHex(root, "requestSha256", label, 64);
            if (!string.Equals(boundRequest, entry.RequestSha256, StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' pins a request digesting to {entry.RequestSha256} and its model start bound was taken over " +
                    $"{boundRequest}. A bound derived from a different plan bounds a different run.");
            }
            var boundHead = StrictJson.RequireString(root, "toolkitHead", label);
            if (!string.Equals(boundHead, _manifest.ToolkitHead, StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' carries a model start bound taken at toolkit head {boundHead} and the cohort pins " +
                    $"{_manifest.ToolkitHead}. The per-attempt limits the bound multiplies live in the toolkit, so a bound from another head is not this build's bound.");
            }

            var maximum = StrictJson.RequireInt(root, "maxRealModelStarts", label, 0, 65536);
            if (entry.EstimatedModelStarts < maximum)
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' estimates {entry.EstimatedModelStarts.ToString(CultureInfo.InvariantCulture)} model start(s) and its sealed bound " +
                    $"admits up to {maximum.ToString(CultureInfo.InvariantCulture)}. The estimate a cohort budgets against is an upper bound or it is a guess, " +
                    "and a guess that runs low spends models nobody authorized.");
            }
            bounded += maximum;

            // The second unit, proved on the same terms. A slot's plan caps how
            // many candidate-by-model assignments the reviewed side may be given -
            // its configured reciprocal models times its candidate cap - and the
            // sum across the declared slots is what an entry may stand on. Read
            // from the sealed artifact rather than restated here, so the two can
            // never be derived from different plans.
            var assignmentMaximum = StrictJson.RequireInt(root, "maxVerifierAssignments", label, 0, 65536);
            if (entry.EstimatedVerifierAssignments < assignmentMaximum)
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' estimates {entry.EstimatedVerifierAssignments.ToString(CultureInfo.InvariantCulture)} verifier assignment(s) and its " +
                    $"sealed bound admits up to {assignmentMaximum.ToString(CultureInfo.InvariantCulture)}. A verifier ceiling declared below the assignments the " +
                    "plan may hand out is the under-declaration that scored a forty-assignment entry as four, and it is refused before anything launches.");
            }
            boundedAssignments += assignmentMaximum;
        }

        // Restated against the global ceiling. The manifest already refused a set
        // whose declared estimates could not fit, but the estimates are the
        // operator's numbers and these are the derived ones; a ceiling that cannot
        // hold the proven worst case is reported here rather than discovered as a
        // hard stop partway through a set that had evidence to show for it.
        if (bounded > _manifest.Budgets.MaximumModelStarts)
        {
            throw new ContractException(
                $"The cohort's sealed bounds admit up to {bounded.ToString(CultureInfo.InvariantCulture)} real model start(s) across its entries and it " +
                $"declares a ceiling of {_manifest.Budgets.MaximumModelStarts.ToString(CultureInfo.InvariantCulture)}. A cohort that cannot fit its own proven " +
                "worst case is refused before it starts rather than stopped after it has produced evidence that will now be abandoned.");
        }
        if (boundedAssignments > _manifest.Budgets.MaximumVerifierAssignments)
        {
            throw new ContractException(
                $"The cohort's sealed bounds admit up to {boundedAssignments.ToString(CultureInfo.InvariantCulture)} real verifier assignment(s) across its " +
                $"entries and it declares a ceiling of {_manifest.Budgets.MaximumVerifierAssignments.ToString(CultureInfo.InvariantCulture)}. A verifier ceiling " +
                "that cannot hold its own proven worst case is refused before anything launches.");
        }
    }

    /// <summary>
    /// Proves, before any child of this cohort exists, that the registry the
    /// manifest binds is the registry on disk and that no declared subject has
    /// already been spent.
    /// </summary>
    /// <remarks>
    /// This is the whole point of the registry: the refusal has to land before a
    /// preparation is launched, because once a model has run the spend is real
    /// whatever the runner decides afterwards. So it sits in the pre-walk beside
    /// the toolkit-head and sealed-bound checks, and it walks EVERY declared entry
    /// rather than checking each one as its turn comes - a two-entry cohort whose
    /// second subject is already counted refuses both, rather than spending the
    /// first and then stopping.
    ///
    /// Which registry revision is acceptable is deliberately two values and not a
    /// range. The manifest binds the revision the operator authorized against;
    /// this cohort then MOVES the registry forward by recording its own samples,
    /// so a resume would refuse its own work if the bound digest were the only
    /// acceptable one. The journal records the revision this cohort last accepted
    /// or produced, and that is the second acceptable value. Anything else - a
    /// revision some other cohort appended to in between, or an edited file - is
    /// refused, because a registry that changed under an authorization is not the
    /// registry that was authorized.
    ///
    /// A subject held by a sample from THIS cohort is not a duplicate; it is this
    /// cohort's own record, seen again on a resume. Only a sample from another
    /// cohort blocks.
    /// </remarks>
    private void RequireRegistryAdmissible(CohortJournal journal, byte[] key)
    {
        if (_manifest.Registry is not { } binding)
        {
            if (_manifest.Execution.IsShippingLaunchProfile)
            {
                // The requirement lives here rather than in the manifest reader on
                // purpose. Reading a registry-less manifest has to keep working -
                // every finished root holds one - but LAUNCHING one that can spend a
                // real pull request without recording which one it spent is how a
                // subject gets spent twice.
                throw new CohortBlockedException(
                    "This cohort names the shipping preparation and binds no registry. A cohort that can spend a real pull request records " +
                    "which one it spent, or the next cohort has no way to know it was spent. Declare a 'registry' section naming the account " +
                    "file, the revision this cohort was authorized against and the subject it occupies, and build the account first with " +
                    "--rebuild-registry if there is not one yet.");
            }
            return;
        }

        var registry = LoadBoundRegistry(journal, binding);
        _registry = registry;

        if (!string.Equals(binding.Mode, CohortRegistryModes.Count, StringComparison.Ordinal))
        {
            // A diagnostic cohort may repeat a subject on purpose - that is what
            // the mode is for - and its samples can never count.
            //
            // What it may NOT do is be the first run over a fresh pull request. A
            // diagnostic row is deliberately invisible to the settle pass, so that
            // repeating a subject does not evict the row it repeats; if such a row
            // were the ONLY thing holding a subject, the models would have seen that
            // pull request and a later cohort would still be free to count it as a
            // first, independent observation. Requiring the subject to be held
            // already keeps the mode exactly what it says it is - a repeat - and
            // leaves the invisibility harmless.
            foreach (var entry in _manifest.Entries)
            {
                var subject = CohortRegistry.SubjectKeyOf(entry);
                if (registry.AnySampleFor(subject) is not null)
                {
                    continue;
                }
                throw new CohortBlockedException(
                    $"Entry '{entry.EntryId}' names pull request {entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} in " +
                    $"'{CohortRegistry.RepositoryIdOf(entry)}', which the registry at '{binding.Path}' has never seen, and registry mode " +
                    $"'{binding.Mode}' records history that cannot count. A first look at a fresh pull request has to be the counting one, " +
                    $"or the subject is spent and the account never learns it. Declare mode '{CohortRegistryModes.Count}', or name a subject " +
                    "the account already holds.");
            }
            _log.WriteLine(
                $"registry {registry.RegistrySha256} accepted in '{binding.Mode}' mode; " +
                $"{registry.CountingSampleCount.ToString(CultureInfo.InvariantCulture)} counted subject(s) on record, none of which this cohort may occupy.");
            return;
        }

        // An unreadable defect is a root that was spent and cannot be read, so the
        // account does not know which subject it holds. A counting cohort asks the
        // account to prove its subject is free, and an account with an open question
        // in it cannot prove that. Diagnostic cohorts are unaffected: they occupy
        // nothing, so nothing has to be provable about them.
        if (registry.UnreadableDefectCount > 0)
        {
            var named = string.Join(
                "; ",
                registry.Defects
                    .Where(defect => string.Equals(defect.Kind, CohortRegistryDefectKinds.Unreadable, StringComparison.Ordinal))
                    .Take(4)
                    .Select(defect => $"'{defect.Source}' ({defect.Reason})"));
            throw new CohortBlockedException(
                $"The registry at '{binding.Path}' records " +
                $"{registry.UnreadableDefectCount.ToString(CultureInfo.InvariantCulture)} root(s) whose evidence could not be read: {named}. " +
                "A run that was spent and cannot be read may have spent this cohort's subject, so a counting cohort cannot prove its subject " +
                "is free. Repair or restore those roots and rebuild the account with --rebuild-registry naming every root, or run under " +
                $"registry mode '{CohortRegistryModes.Diagnostic}' where nothing counts.");
        }

        // Two entries over one pull request in a COUNTING cohort. The manifest's
        // distinctness rule folds the iteration in, so this is a legal manifest; the
        // account cannot honour it, because the second run is history and the operator
        // asked for a count. Said here, before either one spends a model, rather than
        // by the second one's recording failing after it already has.
        var declaredSubjects = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in _manifest.Entries)
        {
            var subject = CohortRegistry.SubjectKeyOf(entry);
            if (declaredSubjects.TryGetValue(subject, out var first))
            {
                throw new CohortBlockedException(
                    $"Entries '{first}' and '{entry.EntryId}' both name pull request " +
                    $"{entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} in '{CohortRegistry.RepositoryIdOf(entry)}', and a counting " +
                    $"cohort spends a subject once. Declare one of them, or run under registry mode '{CohortRegistryModes.Diagnostic}' where a " +
                    "repeat is kept as history and cannot count.");
            }
            declaredSubjects.Add(subject, entry.EntryId);
        }

        foreach (var entry in _manifest.Entries)
        {
            var subject = CohortRegistry.SubjectKeyOf(entry);
            if (!registry.HoldsSubjectFromAnotherRun(subject, _manifest.ManifestSha256))
            {
                RequireOwnRowsCorroborated(journal, registry, binding, entry);
                continue;
            }
            var held = registry.AnySampleFor(subject)!;
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' names pull request {entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} in " +
                $"'{CohortRegistry.RepositoryIdOf(entry)}', and the registry at '{binding.Path}' already holds that subject from cohort " +
                $"'{held.CohortId}' under manifest {held.ManifestSha256} (classified '{held.Classification}'). A counting cohort does not spend " +
                $"a subject twice, and this manifest is not the one that recorded it. Run it under registry mode " +
                $"'{CohortRegistryModes.Diagnostic}' if a repeat is wanted as history, in which case it cannot count.");
        }

        _log.WriteLine(
            $"registry {registry.RegistrySha256} accepted; " +
            $"{registry.CountingSampleCount.ToString(CultureInfo.InvariantCulture)} counted subject(s) on record, " +
            $"{registry.DistinctSubjectCount.ToString(CultureInfo.InvariantCulture)} distinct subject(s) seen, none of them this cohort's.");

        // Recorded once the revision has been authenticated and accepted, so a
        // resume of a cohort that has not yet appended anything still knows which
        // revision it stood on.
        journal.RecordRegistryRevision(key, registry.RegistrySha256);
    }

    /// <summary>
    /// Re-reads the account immediately before a child starts, and refuses a subject
    /// another run has claimed since the pre-walk.
    /// </summary>
    /// <remarks>
    /// The pre-walk settles admission for the whole cohort at once, which is what
    /// lets a two-entry cohort refuse both rather than spend the first. But nothing
    /// outside the account serializes two cohorts, and a second cohort launched
    /// against the same pull request after the pre-walk and before this entry starts
    /// would spend it for real - the write gate would stop the second ROW, and by
    /// then the models have already run.
    ///
    /// So the account is read again here, from disk, in the last moment before the
    /// process exists. It does not close the window - nothing local does, short of
    /// reserving the subject before any evidence exists to record - but it narrows it
    /// from the length of a cohort to the length of a launch, and it costs one read.
    /// A revision that has moved is admitted on the same terms the pre-walk admits
    /// one: bound, this cohort's own, or one step past it.
    /// </remarks>
    private void RequireSubjectStillFree(CohortJournal journal, CohortEntry entry)
    {
        if (_manifest.Registry is not { } binding)
        {
            return;
        }
        if (!string.Equals(binding.Mode, CohortRegistryModes.Count, StringComparison.Ordinal))
        {
            return;
        }

        var registry = LoadBoundRegistry(journal, binding);
        _registry = registry;
        var subject = CohortRegistry.SubjectKeyOf(entry);
        if (!registry.HoldsSubjectFromAnotherRun(subject, _manifest.ManifestSha256))
        {
            RequireOwnRowsCorroborated(journal, registry, binding, entry);
            return;
        }
        var held = registry.AnySampleFor(subject)!;
        throw new CohortBlockedException(
            $"Entry '{entry.EntryId}' names pull request {entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} in " +
            $"'{CohortRegistry.RepositoryIdOf(entry)}', and the registry at '{binding.Path}' has taken that subject since this cohort was " +
            $"admitted - cohort '{held.CohortId}' under manifest {held.ManifestSha256}. Another run claimed it while this one was working, " +
            "and starting now would spend it twice. Nothing has been launched for this entry.");
    }

    /// <summary>
    /// Refuses to launch an entry whose subject the account already holds under THIS
    /// manifest's digest, unless this root's own journal accounts for that row.
    /// </summary>
    /// <remarks>
    /// The exemption a resume depends on is that a run may proceed past a row it
    /// wrote itself, settled by the manifest digest. Left alone, that exemption is
    /// also the way around the whole account: a cohort spends its subject for real,
    /// the journal, its key and the output root are removed, and the byte-identical
    /// manifest is run again. The digest still matches, so the row the account is
    /// holding the subject with reads as this run's own earlier attempt, and the
    /// pull request goes in front of the models a second time - the one thing the
    /// registry exists to prevent, reached without touching the account at all.
    ///
    /// So 'its own' is not settled by the digest alone. The journal in this root has
    /// to account for the row: an ended row needs an ended record, and a row that
    /// holds an open launch needs that launch. A journal minted after the original
    /// was lost has neither, and neither has one that never ran - which is exactly
    /// why this cannot decide the question by itself and refuses instead.
    ///
    /// A hold left by a rebuild that could not read a journal at all can never be
    /// corroborated, and that is the intended reading: the account is saying it
    /// cannot rule out a spend, and the manifest that produced it is no better placed
    /// to rule one out than any other. The escape is the same one the rebuild
    /// advertises - restore the journal, or assert with --retract-cleared-holds that
    /// the launch never happened - and both are the operator on the record.
    ///
    /// The rebuild records NO row for an entry its journal shows as pending, so an
    /// ordinary resume of a partially finished cohort passes here untouched: its
    /// ended entries are corroborated by their endings, and its pending ones are not
    /// held by anything.
    /// </remarks>
    private void RequireOwnRowsCorroborated(
        CohortJournal journal,
        CohortRegistry registry,
        CohortRegistryBinding binding,
        CohortEntry entry)
    {
        var subject = CohortRegistry.SubjectKeyOf(entry);
        foreach (var row in registry.Samples)
        {
            if (!string.Equals(row.SubjectKey, subject, StringComparison.Ordinal)
                || !string.Equals(row.ManifestSha256, _manifest.ManifestSha256, StringComparison.Ordinal))
            {
                continue;
            }
            var record = journal.RecordFor(row.EntryId);
            var placeholder = CohortRegistryAdmission.IsPlaceholder(row);
            if (placeholder ? (record.HasOpenLaunch || record.HasEnded) : record.HasEnded)
            {
                continue;
            }
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' names pull request {entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} in " +
                $"'{CohortRegistry.RepositoryIdOf(entry)}', and the registry at '{binding.Path}' holds that subject with a row this manifest " +
                $"produced (cohort '{row.CohortId}', entry '{row.EntryId}', classified '{row.Classification}') that the journal at " +
                $"'{_manifest.JournalPath}' does not account for: the row stands on evidence of a run, and this journal records no launch and " +
                "no ending for that entry. A journal written after the original was removed reads exactly like one that never ran, so this " +
                "cannot be read as the same run coming back and the subject is not offered again. Restore the journal this account was built " +
                "from, or - if the launch demonstrably never happened - clear the hold deliberately with " +
                "--rebuild-registry --retract-cleared-holds naming this cohort root.");
        }
    }

    /// <summary>
    /// Reads and authenticates the bound registry, and settles which revision this
    /// cohort is allowed to stand on.
    /// </summary>
    private CohortRegistry LoadBoundRegistry(CohortJournal journal, CohortRegistryBinding binding)
    {
        CohortRegistry registry;
        try
        {
            var registryKey = CohortRegistry.LoadOrMintKey(binding.Path, out var keyPreexisted);
            registry = CohortRegistry.LoadOrFresh(binding.Path, registryKey, keyPreexisted);
            _registryKey = registryKey;
        }
        catch (ContractException error)
        {
            // A registry that cannot be read is not an absent registry. Absent is
            // recoverable by starting the account; unreadable means the account
            // exists and its integrity is unknown, and running against it would
            // produce a count nobody can defend.
            throw new CohortBlockedException(
                $"The registry at '{binding.Path}' could not be read as this build's: {error.Message} " +
                "Rebuild it from the immutable cohort roots with --rebuild-registry before running a counting cohort against it.");
        }

        var acceptable = string.Equals(registry.RegistrySha256, binding.Sha256, StringComparison.Ordinal)
            || (!string.Equals(journal.RegistrySha256, "none", StringComparison.Ordinal)
                && string.Equals(registry.RegistrySha256, journal.RegistrySha256, StringComparison.Ordinal))
            || IsOwnUncommittedSuccessor(registry, journal, binding);
        if (!acceptable)
        {
            // Before refusing: an entry that ENDED and whose row never reached the
            // account is the one failure this feature cannot tolerate, and this
            // refusal is raised by the very event that causes it - another cohort
            // writing to the shared account while this one was between its ending and
            // its row. Refusing first and recovering never would leave that subject
            // spent, unheld, and free to be selected again.
            //
            // The rows are derived from the same signed evidence a rebuild would read,
            // and they are written to the account WITHOUT committing a revision to this
            // cohort's journal. That distinction is the whole point: recording what was
            // spent must not double as adopting the registry this cohort was not
            // authorized against, or the refusal would quietly cure itself on the next
            // run.
            var recovered = RecoverEndedSamples(journal, registry);
            var declared = string.Equals(binding.Sha256, CohortRegistryBinding.UnstartedRegistry, StringComparison.Ordinal)
                ? "an unstarted registry"
                : binding.Sha256;
            throw new CohortBlockedException(
                $"The manifest binds {declared} at '{binding.Path}' and the registry there is revision " +
                $"{registry.Revision.ToString(CultureInfo.InvariantCulture)} digesting to {registry.RegistrySha256}" +
                (string.Equals(journal.RegistrySha256, "none", StringComparison.Ordinal)
                    ? "."
                    : $", and this cohort last stood on {journal.RegistrySha256}.") +
                " A registry that moved under an authorization is not the registry that was authorized; re-declare the cohort against the current revision." +
                (recovered.Count == 0
                    ? string.Empty
                    : $" {recovered.Count.ToString(CultureInfo.InvariantCulture)} subject(s) this cohort had already spent were not on record " +
                      $"and were recorded before stopping: {string.Join("; ", recovered)}."));
        }

        return registry;
    }

    /// <summary>
    /// True when the account on disk is exactly one write past what this cohort last
    /// committed to its journal.
    /// </summary>
    /// <remarks>
    /// The one window the ordering leaves open. A sample is recorded in the account
    /// first and the revision it produced is committed to the journal second, so a
    /// runner killed between the two comes back to an account holding a revision the
    /// journal never heard of - which is neither the revision the manifest bound nor
    /// the revision the journal records, and would otherwise block the cohort for
    /// good with its own subjects already held.
    ///
    /// One step, and only one: the revision on disk must say it succeeded exactly
    /// the revision this cohort last stood on. That it authenticates is settled
    /// before this is asked. If the writer was another cohort rather than this one's
    /// dead predecessor, nothing is lost by accepting it - the rows it added were
    /// read in with the file and are carried forward - and if what it added was a
    /// subject THIS cohort declared, the duplicate refusal below still stops the run.
    /// A registry further ahead than one step is not recognised, because the account
    /// moved more than a single interrupted write can explain.
    /// </remarks>
    private bool IsOwnUncommittedSuccessor(
        CohortRegistry registry,
        CohortJournal journal,
        CohortRegistryBinding binding)
    {
        var committed = string.Equals(journal.RegistrySha256, "none", StringComparison.Ordinal)
            ? binding.Sha256
            : journal.RegistrySha256;
        return !string.Equals(committed, CohortRegistryBinding.UnstartedRegistry, StringComparison.Ordinal)
            && string.Equals(registry.PreviousRegistrySha256, committed, StringComparison.Ordinal);
    }

    /// <summary>
    /// Records the sample for an entry that ended before this run started, when the
    /// account does not already hold it.
    /// </summary>
    /// <remarks>
    /// The other half of the ordering. An ending is committed to the journal before
    /// its sample reaches the account, so a kill between the two leaves a subject
    /// that was really spent with nothing on record saying so - and the walk skips
    /// an ended entry, so nothing would ever go back for it. That is the single
    /// failure this whole feature cannot tolerate: the next cohort would offer the
    /// pull request again and admission would let it through.
    ///
    /// Re-derived from the same signed evidence a rebuild would use, and idempotent
    /// by sample key, so the ordinary case - the sample is already there - costs a
    /// lookup and writes nothing.
    /// </remarks>
    private void RecordEndedEntrySample(CohortJournal journal, byte[] key, CohortEntry entry, CohortEntryRecord record)
    {
        if (_manifest.Registry is null || _registry is not { } registry)
        {
            return;
        }
        var subject = CohortRegistry.SubjectKeyOf(entry);
        var sampleKey = CohortRegistry.SampleKeyOf(subject, _manifest.CohortId, entry.EntryId, record.AuditSha256);
        if (registry.SampleFor(sampleKey) is not null)
        {
            return;
        }
        CohortEntrySummary summary;
        string authorizedBy;
        try
        {
            summary = CohortSummaryReader.Read(entry, record, record.ElapsedSeconds, CorrelationOf(entry));
            // The same check the rebuild applies. Without it a resumed runner would
            // score an audit the journal never committed to, and the account it
            // wrote would disagree with the account a rebuild derives from the very
            // same root - two signed answers to one question.
            RequireCommittedDigests(entry, record, summary);
            // And the alias this entry actually launched under, not the one on this
            // process's command line. A cohort started by one operator and resumed
            // with a different --authorized-by would otherwise record an authorization
            // that operator never gave, and a rebuild - which reads the alias from the
            // launch intent the journal pins by digest - would silently correct it,
            // so two accounts over one root would disagree about who spent the subject.
            authorizedBy = CohortRegistryRebuild.ReadAuthorizedBy(_manifest, entry, record);
        }
        catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
        {
            // The subject is held first, then the cohort stops. This entry ended, so
            // its pull request really was put in front of whatever the run started;
            // letting the refusal escape with no row would leave that subject free for
            // the next selection, which is the one failure the account exists to
            // prevent. The row says exactly what is true - the evidence would not read
            // - and it counts toward nothing.
            RecordUnreadableEntrySample(journal, key, entry, record);
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' ended before this run and the account does not hold its sample, and its evidence could not be " +
                $"re-read to record one: {error.Message} Its subject is held by a row that counts toward nothing so it is not offered " +
                "again, and this cohort stops rather than going on.");
        }
        _log.WriteLine($"entry '{entry.EntryId}' ended earlier with no sample on record; recording it now.");
        RecordRegistrySample(journal, key, entry, summary, record.Outcome, authorizedBy);
    }

    /// <summary>
    /// The row one finished entry leaves, built from the journal and its evidence.
    /// </summary>
    /// <remarks>
    /// Held by anything but this same run: another cohort's row, or an earlier entry
    /// of THIS cohort over the same pull request. A manifest may declare the same
    /// subject twice at two iterations - the distinctness rule folds the iteration in
    /// and the subject key deliberately does not - and the second one is history, not
    /// a second spend.
    ///
    /// Same run means same cohort AND same entry AND the same manifest digest, not
    /// merely the same sample key. A rebuild run over this root before the entry ended
    /// leaves a placeholder row keyed on the manifest digest rather than on an audit
    /// that did not exist yet; the real ending arrives under a different sample key,
    /// and reading that placeholder as somebody else's observation would demote this
    /// run to a repeat of itself and put its subject permanently out of reach. The
    /// manifest digest is what keeps that exemption from being claimable by a DIFFERENT
    /// cohort that happens to reuse a cohort id and an entry id - 'entry1' is the
    /// obvious collision - and so quietly counting a second spend of one subject. This
    /// run's manifest digest cannot change under it: a manifest re-bound to another
    /// registry is a different manifest, and the journal refuses to resume under one.
    /// </remarks>
    private CohortRegistrySample BuildRegistrySample(
        CohortJournal journal,
        CohortRegistry registry,
        CohortEntry entry,
        CohortEntrySummary summary,
        string outcome,
        string authorizedBy)
    {
        var subject = CohortRegistry.SubjectKeyOf(entry);
        var sampleKey = CohortRegistry.SampleKeyOf(subject, _manifest.CohortId, entry.EntryId, summary.AuditSha256);
        var heldElsewhere = registry.Samples.Any(existing =>
            string.Equals(existing.SubjectKey, subject, StringComparison.Ordinal)
            && !string.Equals(existing.SampleKey, sampleKey, StringComparison.Ordinal)
            && !(string.Equals(existing.CohortId, _manifest.CohortId, StringComparison.Ordinal)
                && string.Equals(existing.EntryId, entry.EntryId, StringComparison.Ordinal)
                && string.Equals(existing.ManifestSha256, _manifest.ManifestSha256, StringComparison.Ordinal))
            && (existing.CountsTowardThreshold
                || CohortRegistryClassifications.IsPriorObservation(existing.Classification, existing.RealModelStarts)));
        return CohortRegistryAdmission.SampleFor(
            _manifest,
            entry,
            summary,
            outcome,
            authorizedBy,
            heldElsewhere,
            summary.Record.EndedAtUtc,
            SpentBefore(journal, entry));
    }

    /// <summary>
    /// Records the rows of entries that already ended and are missing from the
    /// account, without adopting the revision they are written into.
    /// </summary>
    /// <remarks>
    /// Called on the one path that would otherwise strand them: the registry moved
    /// out from under this cohort's authorization, so the run is about to be refused
    /// for good, and the same concurrent write that moved it is what stops an ending
    /// from reaching the account in the first place.
    ///
    /// Best effort by construction. Every row here is re-derived from signed evidence
    /// and idempotent by sample key, so a rebuild over this root produces the same
    /// rows; an entry whose evidence will not read is held by the row that says so
    /// rather than left free. Nothing here writes the journal, and nothing here is
    /// allowed to replace the refusal the caller is raising - a failure to record is
    /// logged and named, and the refusal still stops the run.
    /// </remarks>
    private List<string> RecoverEndedSamples(CohortJournal journal, CohortRegistry registry)
    {
        var recovered = new List<string>();
        if (_manifest.Registry is not { } binding || _registryKey is not { } registryKey)
        {
            return recovered;
        }
        foreach (var entry in _manifest.Entries)
        {
            var record = journal.RecordFor(entry.EntryId);
            if (!record.HasEnded)
            {
                continue;
            }
            var subject = CohortRegistry.SubjectKeyOf(entry);
            if (registry.SampleFor(CohortRegistry.SampleKeyOf(subject, _manifest.CohortId, entry.EntryId, record.AuditSha256)) is not null)
            {
                continue;
            }
            CohortRegistrySample sample;
            try
            {
                var summary = CohortSummaryReader.Read(entry, record, record.ElapsedSeconds, CorrelationOf(entry));
                RequireCommittedDigests(entry, record, summary);
                sample = BuildRegistrySample(
                    journal,
                    registry,
                    entry,
                    summary,
                    record.Outcome,
                    CohortRegistryRebuild.ReadAuthorizedBy(_manifest, entry, record));
            }
            catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
            {
                sample = CohortRegistryAdmission.UnreadableSampleFor(
                    _manifest,
                    entry,
                    record,
                    CohortRegistryRebuild.ReadAuthorizedByOrUnknown(_manifest, entry, record));
            }
            if (registry.SampleFor(sample.SampleKey) is not null)
            {
                continue;
            }
            try
            {
                registry.Record(registryKey, sample);
                recovered.Add(
                    $"pull request {entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} from entry '{entry.EntryId}' " +
                    $"as '{sample.Classification}'");
            }
            catch (Exception error) when (error is ContractException or IOException or UnauthorizedAccessException)
            {
                _log.WriteLine(
                    $"registry {binding.Path} could not be told that entry '{entry.EntryId}' spent its subject: {error.Message} " +
                    "The subject may be offered again; rebuild the account from this cohort's root before selecting.");
            }
        }
        return recovered;
    }

    /// <summary>
    /// Puts every already-ended entry on record before a refusal raised on the way in
    /// stops the cohort, without adopting the account it writes to.
    /// </summary>
    /// <remarks>
    /// The one ordering hole the account has. A runner is killed between an entry's
    /// ending and its row; the resume re-publishes the index first, and if that
    /// entry's artifacts are the damaged ones, the refusal is raised before the
    /// account has been opened at all - so the walk that would have recorded the row
    /// never runs, and the subject is spent with nothing on record.
    ///
    /// Every failure here is swallowed and named. This is the error path already; a
    /// second fault while trying to hold a subject must not replace the refusal the
    /// caller is raising, which is the more informative of the two. What the operator
    /// is told, either way, is to rebuild the account from this root before selecting
    /// - the rebuild reads the same evidence and reaches the same rows.
    /// </remarks>
    private void HoldSpentSubjectsBeforeFailing(CohortJournal journal)
    {
        if (_manifest.Registry is not { } binding || !File.Exists(binding.Path))
        {
            return;
        }
        try
        {
            // Read, never minted. An account that is not there cannot be holding
            // anything, and minting a key beside a file that does not exist would
            // leave a signing key for an account nobody ever wrote.
            var registryKey = CohortRegistry.LoadOrMintKey(binding.Path, out _);
            _registryKey ??= registryKey;
            var registry = CohortRegistry.Load(binding.Path, registryKey);
            var recovered = RecoverEndedSamples(journal, registry);
            if (recovered.Count > 0)
            {
                _log.WriteLine(
                    $"registry {binding.Path} recorded {recovered.Count.ToString(CultureInfo.InvariantCulture)} subject(s) this cohort had " +
                    $"already spent before stopping: {string.Join("; ", recovered)}.");
            }
        }
        catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
        {
            _log.WriteLine(
                $"registry {binding.Path} could not be told what this cohort had already spent: {error.Message} " +
                "Rebuild the account from this cohort's root with --rebuild-registry before selecting again.");
        }
    }

    /// <summary>
    /// Records what one finished entry proved about its subject, counted or not.
    /// </summary>
    /// <remarks>
    /// Called after the ending is committed, never before: the sample carries the
    /// summary digest and the terminal outcome as the journal holds them, so a
    /// runner killed between the two leaves a closed entry with no sample rather
    /// than a sample for an entry with no ending. The resume re-derives the same
    /// sample from the same evidence and records it then, and because the sample
    /// key is derived from the audit digest the second recording lands on the same
    /// bytes rather than adding a row.
    ///
    /// Every finished entry leaves a sample. A failed, refused, over-budget or
    /// unauthorized entry is recorded as history that does not count, because an
    /// account that only remembers its successes cannot answer 'has this pull
    /// request been used before'.
    /// </remarks>
    private void RecordRegistrySample(
        CohortJournal journal,
        byte[] key,
        CohortEntry entry,
        CohortEntrySummary summary,
        string outcome,
        string authorizedBy)
    {
        if (_manifest.Registry is not { } binding || _registry is not { } registry)
        {
            return;
        }

        var sample = BuildRegistrySample(journal, registry, entry, summary, outcome, authorizedBy);

        try
        {
            registry.Record(_registryKey!, sample);
        }
        catch (ContractException error)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' finished and its sample could not be recorded in the registry at '{binding.Path}': {error.Message} " +
                "The entry's own artifacts stand; the cohort stops rather than going on with an account it could not update.");
        }
        journal.RecordRegistryRevision(key, registry.RegistrySha256);
        _log.WriteLine(
            $"registry {binding.Path} revision {registry.Revision.ToString(CultureInfo.InvariantCulture)} " +
            $"({registry.RegistrySha256}) recorded entry '{entry.EntryId}' as '{sample.Classification}' " +
            $"countsTowardThreshold={(sample.CountsTowardThreshold ? "true" : "false")}; " +
            $"{registry.CountingSampleCount.ToString(CultureInfo.InvariantCulture)} counted subject(s) on record.");
    }

    /// <summary>
    /// Records the row an entry leaves when its own evidence could not be read.
    /// </summary>
    /// <remarks>
    /// The refusal path's other half. The ending is committed first, exactly as it
    /// is for an entry that ended cleanly, and the row follows; a runner killed in
    /// between comes back to an ended entry with no sample, which the resume walk's
    /// <see cref="RecordEndedEntrySample"/> goes back for.
    ///
    /// The refusal that brought us here is re-thrown by the caller, so this must not
    /// replace it with a failure of its own. An account that cannot be updated is
    /// reported and the original refusal stands: the entry is closed either way, and
    /// the cohort is stopping regardless.
    /// </remarks>
    private void RecordUnreadableEntrySample(CohortJournal journal, byte[] key, CohortEntry entry, CohortEntryRecord record)
    {
        if (_manifest.Registry is not { } binding || _registry is not { } registry)
        {
            return;
        }
        var sample = CohortRegistryAdmission.UnreadableSampleFor(
            _manifest,
            entry,
            record,
            CohortRegistryRebuild.ReadAuthorizedByOrUnknown(_manifest, entry, record));
        if (registry.SampleFor(sample.SampleKey) is not null)
        {
            return;
        }
        try
        {
            registry.Record(_registryKey!, sample);
            journal.RecordRegistryRevision(key, registry.RegistrySha256);
            _log.WriteLine(
                $"registry {binding.Path} revision {registry.Revision.ToString(CultureInfo.InvariantCulture)} " +
                $"({registry.RegistrySha256}) holds subject of entry '{entry.EntryId}' as '{sample.Classification}': its evidence " +
                "could not be read, and an unheld subject would be offered again.");
        }
        catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
        {
            _log.WriteLine(
                $"registry {binding.Path} could not be told that entry '{entry.EntryId}' spent its subject: {error.Message} " +
                "The subject may be offered again; rebuild the account from this cohort's root before selecting.");
        }
    }

    /// <summary>
    /// What the cohort's earlier entries had already spent, from the signed journal.
    /// </summary>
    /// <remarks>
    /// Read the same way the budget stop reads it - ended entries only, actuals plus
    /// whatever allowance was left unmeasured - so a sample is held to the same total
    /// the runner itself refuses to cross. Entries after this one contribute nothing:
    /// they had not run when it did.
    /// </remarks>
    private CohortRegistryAdmission.Spent SpentBefore(CohortJournal journal, CohortEntry entry)
    {
        long models = 0;
        long verifiers = 0;
        long seconds = 0;
        foreach (var declared in _manifest.Entries)
        {
            if (declared.Ordinal >= entry.Ordinal)
            {
                continue;
            }
            var record = journal.RecordFor(declared.EntryId);
            if (!record.HasEnded)
            {
                continue;
            }
            models += record.ModelStartCount + record.ModelStartUnmeasuredAllowance;
            verifiers += record.VerifierAssignmentCount + record.VerifierAssignmentUnmeasuredAllowance;
            seconds += record.ElapsedSeconds;
        }
        return new CohortRegistryAdmission.Spent(models, verifiers, seconds);
    }

    /// <summary>
    /// Requires every entry that declares slots to have the launch authorization
    /// its own request names, before any entry is started.
    /// </summary>
    /// <remarks>
    /// A slots-carrying entry can be sealed, sealable, walkable and standing at
    /// runSetReady while naming a launch authorization that no declaration ever
    /// published. Everything about it reads as ready; the first thing that
    /// notices is the first slot prelaunch, which is after the cohort has been
    /// assembled around it and after an operator has spent the one execution
    /// they were authorized. That is the wrong place to find out, so the whole
    /// set is checked here, in the same pre-walk pass that proves the model
    /// start bounds, where refusing costs nothing.
    ///
    /// Only EXISTENCE and shape are checked here, deliberately. The token's
    /// digest is sealed into the run set's plan, and the reviewed prelaunch path
    /// reproduces that plan from the token it reads - so a substituted token is
    /// already refused there, by the party that holds the plan. Re-deriving the
    /// plan digest in this pass would be a second answer to a question the
    /// signed declaration already answers.
    /// </remarks>
    private void RequireDeclaredLaunchAuthorizations()
    {
        foreach (var entry in _manifest.Entries)
        {
            var label = $"entry '{entry.EntryId}' request";
            var request = StrictJson.ReadObjectFile(entry.RequestPath, label);
            if (!request.TryGetProperty("slots", out var slots) || slots.ValueKind != System.Text.Json.JsonValueKind.Object)
            {
                // A preparation-only entry authorizes no launch and needs no
                // authorization to launch with.
                continue;
            }

            var seen = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var declared in StrictJson.RequireArray(slots, "declared", label))
            {
                seen.Add(StrictJson.RequireString(declared, "launchAuthorizationTokenPath", label));
            }
            seen.Add(StrictJson.RequireString(StrictJson.RequireObject(slots, "reconciliation", label), "launchAuthorizationTokenPath", label));
            seen.Add(StrictJson.RequireString(StrictJson.RequireObject(slots, "delivery", label), "launchAuthorizationTokenPath", label));
            if (seen.Count != 1)
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' names {seen.Count.ToString(CultureInfo.InvariantCulture)} distinct launch authorizations across its slots, " +
                    "reconciliation and delivery. One preparation declares one run set and one run set publishes one authorization, so more than one path " +
                    "means at least one of them belongs to a different run.");
            }

            var tokenPath = seen.Min!;
            if (!File.Exists(tokenPath))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' declares slots authorized by '{tokenPath}', and there is no such file. A run set declaration publishes that " +
                    "token; an entry naming one that was never published cannot launch a single slot, and the cohort refuses it here rather than at the " +
                    "first prelaunch, after the run it was going to spend is gone.");
            }
            var text = StrictJson.StrictUtf8.GetString(StrictJson.ReadFileBytes(tokenPath, $"entry '{entry.EntryId}' launch authorization", 4096));
            if (text.Length != 64 || !StrictJson.IsLowerHex(text))
            {
                throw new ContractException(
                    $"Entry '{entry.EntryId}' declares a launch authorization at '{tokenPath}' that is not the 64 lowercase hex characters a published " +
                    "authorization holds. What the prelaunch hashes has to be the token the declaration minted.");
            }
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
            models += record.ModelStartCount + record.ModelStartUnmeasuredAllowance;
            verifiers += record.VerifierAssignmentCount + record.VerifierAssignmentUnmeasuredAllowance;
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

    /// <summary>
    /// Names the ceiling the entries that have ALREADY ENDED have crossed, or
    /// null when they fit.
    /// </summary>
    /// <remarks>
    /// Actuals only, and read out of the signed journal, which carries what each
    /// entry's own signed audit reported it really spent. This is the check with
    /// teeth: the sealed estimates admit an entry before it runs, and this one
    /// stops the cohort when what an entry actually cost turns out to be more
    /// than the whole set was allowed. It is deliberately evaluated even when
    /// nothing is left to launch, so a cohort that overspent on its last entry
    /// reports that instead of a clean completion.
    ///
    /// The model figure is real model subprocess starts plus the bounded
    /// allowance for slots interrupted before they could publish an attempt
    /// record - an upper bound, because a ceiling checked against a floor is not
    /// a ceiling.
    /// </remarks>
    private string? DescribeOverspend(CohortJournal journal)
    {
        long models = 0;
        long verifiers = 0;
        long seconds = 0;
        foreach (var declared in _manifest.Entries)
        {
            var record = journal.RecordFor(declared.EntryId);
            if (!record.HasEnded)
            {
                continue;
            }
            models += record.ModelStartCount + record.ModelStartUnmeasuredAllowance;
            verifiers += record.VerifierAssignmentCount + record.VerifierAssignmentUnmeasuredAllowance;
            seconds += record.ElapsedSeconds;
        }
        if (models > _manifest.Budgets.MaximumModelStarts)
        {
            return Overspent("real model start", models, _manifest.Budgets.MaximumModelStarts);
        }
        if (verifiers > _manifest.Budgets.MaximumVerifierAssignments)
        {
            return Overspent("verifier assignment", verifiers, _manifest.Budgets.MaximumVerifierAssignments);
        }
        if (seconds > _manifest.Budgets.MaximumWallClockSeconds)
        {
            return Overspent("wall clock second", seconds, _manifest.Budgets.MaximumWallClockSeconds);
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

    private static string Overspent(string unit, long consumed, int ceiling) =>
        $"the cohort has already consumed {consumed.ToString(CultureInfo.InvariantCulture)} {unit}(s) against a ceiling of " +
        $"{ceiling.ToString(CultureInfo.InvariantCulture)}. The entries that ran keep their results and are never re-run; no further " +
        "entry launches under this manifest.";

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

    /// <summary>
    /// Whether an already-ended entry counts as complete, by the same rule the
    /// index publishes.
    /// </summary>
    /// <remarks>
    /// A journal written by a build that read the exit code alone records an entry
    /// that halted at the declared target as faulted. Judging a resume by that
    /// record while the index adopts the same entry would let one run publish two
    /// contradictory accounts of it - a stop policy that stopped, over an index
    /// naming the entry it stopped for as adopted-complete. So both ask the same
    /// question of the same artifacts, in the same order: the committed digests
    /// first, then the adoption. Neither refusal is caught here. An audit that no
    /// longer reproduces what it was accounted for is tamper wherever it is found,
    /// and answering 'not complete' to it would let a walk carry on past evidence
    /// the index is about to stop over anyway.
    ///
    /// Only a CLEAN ending short-circuits. A record already marked complete with a
    /// non-zero exit is a record some earlier run adopted, and it is re-proved
    /// here rather than taken on trust: the index publication at the top of the
    /// walk would catch artifacts that moved since, but between that publication
    /// and this loop is exactly the window in which the next entry would be
    /// launched on the strength of an adoption that no longer holds.
    /// </remarks>
    private bool CountsAsComplete(CohortEntry entry, CohortEntryRecord record)
    {
        if (record.EndedComplete && record.ExitCode == CoordinatorExitCodes.Ok)
        {
            return true;
        }
        if (!record.HasEnded || record.EndedRefused || !CohortCompletionAdoption.IsAdoptableExit(record.ExitCode))
        {
            return false;
        }
        var summary = CohortSummaryReader.Read(entry, record, record.ElapsedSeconds, CorrelationOf(entry));
        RequireCommittedDigests(entry, record, summary);
        return CohortCompletionAdoption.Evaluate(_manifest, summary).Adopted;
    }

    internal static void RequireCommittedDigests(CohortEntry entry, CohortEntryRecord record, CohortEntrySummary summary)
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
