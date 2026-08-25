using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Rebuilds the durable subject account from finished cohort roots.
/// </summary>
/// <remarks>
/// The account exists to answer one question - has this pull request already been
/// spent - and an answer nobody can re-derive is not evidence. So the rebuild
/// reads the same artifacts a run reads: the manifest as it was sealed, the signed
/// journal beside it, and each entry's own authenticated preparation audit. It
/// takes NOTHING from a published summary or index, because those are documents a
/// run wrote about itself and re-reading them would only prove they still say what
/// they said.
///
/// Roots it cannot read are recorded, not skipped. A rebuild that quietly dropped
/// an unreadable root would report a smaller reach than the toolkit really has,
/// and an operator would spend a subject believing it was free.
///
/// A root declared under a contract this build refuses to load is classified
/// rather than parsed: its subjects are recorded as history that cannot count,
/// because the budget units those contracts declared were the unsafe ones. Its
/// identity is still read - leniently, from the manifest bytes alone - so an
/// operator can see that the pull request was used, even though the sample does
/// not occupy it.
/// </remarks>
internal static class CohortRegistryRebuild
{
    internal static int Run(
        string registryPath,
        IReadOnlyList<string> manifestPaths,
        string operatorAlias,
        bool retractClearedHolds,
        TextWriter log)
    {
        var samples = new List<CohortRegistrySample>();
        var defects = new List<(string Kind, string Source, string Reason)>();
        // The entries this rebuild PROVED were never launched, from their own
        // authenticated journals. Nothing else clears a hold.
        var cleared = new List<string>();

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // Every path a NAMED cohort owns: its journal root and its entries' output
        // roots. A defect raised against something inside one of them is offered for
        // re-reading when that cohort is named, and only then. Scoping by the
        // manifest's parent DIRECTORY instead would make sibling manifests satisfy
        // each other - and in the layout these roots actually use, several cohorts
        // sit side by side in one directory, so naming any one of them would drop
        // every other one's defects and free the subjects they hold.
        var ownedScopes = new List<string>();
        foreach (var declared in manifestPaths)
        {
            var manifestPath = Path.GetFullPath(declared);
            if (!seen.Add(manifestPath))
            {
                // The same root named twice is the caller repeating themselves, not
                // two runs, and not a property of the evidence. Logging it keeps the
                // count of roots read honest without persisting an argv accident into
                // the account - where, as a defect source, it would then have to be
                // reproduced by every later rebuild.
                log.WriteLine($"{manifestPath}: named more than once; read once.");
                continue;
            }
            if (!File.Exists(manifestPath))
            {
                // A path with nothing at it is a caller's mistake, not evidence. If it
                // were filed as a defect it would be signed into the account, every
                // later rebuild would have to name it again, and - because an
                // unreadable defect stops counting - a single mistyped argument would
                // deadlock Gate5 against a root that never existed to be repaired.
                throw new ContractException(
                    $"There is no cohort manifest at '{manifestPath}'. A rebuild accounts for roots that exist; a path with nothing at it " +
                    "would be signed into the account as a root nobody can read and could never be cleared. Correct the path and run again.");
            }
            CollectOwnedScopes(manifestPath, ownedScopes);
            try
            {
                ReadCohort(manifestPath, samples, defects, cleared, log);
            }
            catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
            {
                defects.Add((CohortRegistryDefectKinds.Unreadable, manifestPath, error.Message));
                log.WriteLine($"defect {manifestPath}: {error.Message}");
            }
        }

        SettleOneCountingSamplePerSubject(samples, defects);

        var key = CohortRegistry.LoadOrMintKey(registryPath, out _);
        var previousRevision = 0;
        var previousSha256 = "none";
        if (File.Exists(registryPath))
        {
            // A rebuild replaces the contents and continues the chain; it does not
            // start a new account beside an old one. An existing file that cannot
            // be authenticated is not overwritten silently, because overwriting it
            // would destroy the only evidence of what it used to claim.
            var existing = CohortRegistry.Load(registryPath, key);
            previousRevision = existing.Revision;
            previousSha256 = existing.RegistrySha256;
            RequireNoEvidenceLost(existing, samples, defects, seen, ownedScopes, cleared, retractClearedHolds, registryPath);
        }

        var rebuilt = CohortRegistry.ForRebuild(registryPath, previousRevision, previousSha256, samples, defects);
        rebuilt.Publish(key);

        log.WriteLine(
            $"registry {registryPath} revision {rebuilt.Revision.ToString(CultureInfo.InvariantCulture)} ({rebuilt.RegistrySha256}) " +
            $"evidence {rebuilt.EvidenceSha256} " +
            $"rebuilt from {seen.Count.ToString(CultureInfo.InvariantCulture)} root(s) by {operatorAlias}: " +
            $"{rebuilt.CountingSampleCount.ToString(CultureInfo.InvariantCulture)} counted subject(s), " +
            $"{rebuilt.DistinctSubjectCount.ToString(CultureInfo.InvariantCulture)} distinct subject(s), " +
            $"{samples.Count.ToString(CultureInfo.InvariantCulture)} sample(s), " +
            $"{defects.Count.ToString(CultureInfo.InvariantCulture)} defect(s).");
        return CoordinatorExitCodes.Ok;
    }

    /// <summary>
    /// Refuses a rebuild that would let go of any evidence the account already holds.
    /// </summary>
    /// <remarks>
    /// The account is what stops a pull request being spent twice, and a rebuild
    /// writes it whole. A caller who names the newest root and forgets the rest
    /// would publish a smaller account that authenticates perfectly and frees every
    /// subject it no longer mentions - the same silent loss requirement 3 forbids
    /// for an unreadable root, arriving through the front door.
    ///
    /// Subjects are not enough to hold it to. A rebuild that reached a subject by a
    /// different run would satisfy a subject-only test while dropping the rows and
    /// the defects that said what else had happened to it - and a defect is exactly
    /// the record of a root nobody could read, which is the record most worth losing
    /// if one wanted a cleaner-looking account. So every sample key and every defect
    /// source the current revision carries must be reached too, and the refusal names
    /// what is missing.
    ///
    /// A defect source is held to being NAMED again, not to failing again. The whole
    /// remedy this account advertises - repair the root, then rebuild - would be
    /// impossible otherwise: repairing an unreadable root removes the defect, and a
    /// guard that demanded the defect back would wedge the account permanently on the
    /// very fix it asked for. Naming is the part that matters; whether the root reads
    /// this time is what the rebuild is there to find out.
    /// </remarks>
    private static void RequireNoEvidenceLost(
        CohortRegistry existing,
        IReadOnlyList<CohortRegistrySample> rebuilt,
        IReadOnlyList<(string Kind, string Source, string Reason)> defects,
        IReadOnlyCollection<string> namedRoots,
        IReadOnlyCollection<string> ownedScopes,
        IReadOnlyCollection<string> cleared,
        bool retractClearedHolds,
        string registryPath)
    {
        var reachedSubjects = new HashSet<string>(
            rebuilt.Select(sample => sample.SubjectKey),
            StringComparer.Ordinal);
        var reachedSamples = new HashSet<string>(
            rebuilt.Select(sample => sample.SampleKey),
            StringComparer.Ordinal);
        // Paths, compared the way the file system compares them here and the way the
        // caller's own de-duplication compared them. An Ordinal test would refuse a
        // rebuild over the same roots typed with a different drive-letter case.
        var reachedDefects = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        reachedDefects.UnionWith(defects.Select(defect => defect.Source));
        reachedDefects.UnionWith(namedRoots);
        // A defect raised against something a cohort owns - an entry output root whose
        // evidence would not read - is named again when that cohort is named again,
        // because naming the cohort is the only way a caller can offer it for
        // re-reading. Every defect this build raises is sourced either at a manifest
        // path or at a root that manifest declares, so ownership is settled by exact
        // membership and never by a path prefix.
        //
        // Prefix scoping was the obvious way to write this and it is the wrong one. A
        // declared root is an arbitrary caller-supplied string: a manifest declaring
        // 'D:\' owns that whole drive under a StartsWith test, and naming it once would
        // clear every unreadable defect on the machine - dropping the account's open
        // questions to zero and re-opening both the launch gate and selection while the
        // unread roots stayed exactly as unread as before. Exact membership costs
        // nothing here and keeps the widest a bogus manifest can reach down to the
        // exact paths it wrote out.
        //
        // The scopes are collected leniently, ahead of validation, so a manifest that
        // never validates can still declare paths here. That is deliberate and it is
        // safe: this set only decides whether a defect this same build raised is
        // ANSWERED, and clears nothing that is not re-read. It has no say in whether a
        // subject's hold is retracted - only an authenticated journal does that.
        reachedDefects.UnionWith(ownedScopes);

        bool WasNamedAgain(string source) => reachedDefects.Contains(source);

        // The entries an authenticated journal PROVED were never launched.
        var clearedRuns = new HashSet<string>(cleared, StringComparer.Ordinal);

        // A row that a LATER reading of the same run supersedes. A cohort root that
        // was prepared but not yet launched, or launched and interrupted, is recorded
        // by a PLACEHOLDER keyed on the manifest digest rather than on an audit that
        // did not exist yet; when that same run later ends, the same cohort, entry and
        // subject arrive keyed on the real audit digest. Holding the account to the
        // placeholder key would refuse every rebuild after the run finished - the
        // account would be frozen at the moment it was least informed.
        //
        // The identity of a run is NOT its cohort id and entry id. Those are strings
        // an operator types, and 'entry1' is the obvious collision; a later manifest
        // that reuses both over the same pull request would otherwise be able to speak
        // for a run it has nothing to do with. The manifest digest is what makes it a
        // particular run, and both placeholder shapes already record it.
        static string RunIdentity(CohortRegistrySample sample) =>
            sample.CohortId + "\u001f" + sample.EntryId + "\u001f" + sample.SubjectKey + "\u001f" + sample.ManifestSha256;

        var reachedRuns = new HashSet<string>(rebuilt.Select(RunIdentity), StringComparer.Ordinal);

        // A subject held ONLY by placeholders, every one of them for the very run this
        // rebuild has now PROVED was never launched, MAY be let go - but only when the
        // operator asks for it in as many words. A placeholder is a statement of
        // ignorance: 'this root could not be read, so its subject is held rather than
        // handed out.' The one thing that speaks to it is the entry's own authenticated
        // journal saying no launch was ever committed, bound to the manifest digest so
        // that only that run's journal can answer for it.
        //
        // That is still not proof, and this is where the honest limit of the account
        // sits. If a journal and its key are both lost, a later run of the same
        // manifest MINTS a fresh journal, and a fresh journal's entries are pending -
        // indistinguishable, from the outside, from an original that never launched.
        // So automatic retraction would let exactly the accident this account exists to
        // prevent walk straight through it: lose a journal, re-run, rebuild, and a pull
        // request that really was put in front of the models comes back as fresh.
        //
        // Leaving no escape at all is not the answer either: a root whose key alone
        // went missing would hold its subjects forever, with no argument that could
        // ever clear them. So the escape exists and is deliberate. Without the flag a
        // hold is never retracted and a rebuild that cannot account for one refuses;
        // with it, the operator is asserting - under their own recorded alias, into a
        // signed file - that the journal now being read is the original.
        bool IsRetractable(CohortRegistrySample sample) =>
            retractClearedHolds
            && CohortRegistryAdmission.IsPlaceholder(sample)
            && clearedRuns.Contains(RunIdentity(sample));

        var retractable = existing.Samples
            .GroupBy(sample => sample.SubjectKey, StringComparer.Ordinal)
            .Where(group => group.All(IsRetractable))
            .Select(group => group.Key)
            .ToHashSet(StringComparer.Ordinal);

        var lost = existing.Samples
            .Where(sample => !reachedSubjects.Contains(sample.SubjectKey))
            .Where(sample => !retractable.Contains(sample.SubjectKey))
            .GroupBy(sample => sample.SubjectKey, StringComparer.Ordinal)
            .Select(group => group.First())
            .OrderBy(sample => sample.SubjectKey, StringComparer.Ordinal)
            .ToList();
        if (lost.Count > 0)
        {
            var named = string.Join(
                "; ",
                lost.Select(sample =>
                    $"pull request {sample.PullRequestId.ToString(CultureInfo.InvariantCulture)} in '{sample.RepositoryId}' " +
                    $"(cohort '{sample.CohortId}', run root '{sample.RunRoot}')"));
            // Said only when it is true. A subject whose rows are all placeholders that
            // this rebuild's own authenticated journals cleared is exactly the case the
            // flag exists for, and an operator who is not told the argument exists will
            // reach for deleting the account instead. Every other subject gets the plain
            // refusal, because for those the flag would not have helped.
            var clearable = lost.Any(sample => existing.Samples
                .Where(row => string.Equals(row.SubjectKey, sample.SubjectKey, StringComparison.Ordinal))
                .All(row => CohortRegistryAdmission.IsPlaceholder(row) && clearedRuns.Contains(RunIdentity(row))));
            var remedy = clearable
                ? " At least one of those subjects is held only by rows about entries the journals in this rebuild say were never launched. "
                  + "If you can vouch that those journals are the originals rather than ones minted after the evidence was lost, "
                  + "re-run with --retract-cleared-holds."
                : string.Empty;
            throw new ContractException(
                $"The registry at '{registryPath}' holds {lost.Count.ToString(CultureInfo.InvariantCulture)} subject(s) that this rebuild did " +
                $"not reach, and publishing it would free them to be spent again: {named}. Name every root the account already accounts for, " +
                "or rebuild to a new path and reconcile the two deliberately." + remedy);
        }

        // Only a placeholder may be superseded, and only toward a row for the same run:
        // same cohort, same entry, same subject AND the same manifest digest - or
        // toward a retraction the operator asked for. Allowing any row to be superseded
        // on cohort id and entry id alone would let a new manifest that happens to reuse
        // them - 'entry1' is the obvious collision - quietly replace a row that recorded
        // a real prior observation with one that counts. That is a mis-count an honest
        // operator could reach by accident, so the direction is restricted to the one
        // the placeholder exists for: unknown, then known, about the same run.
        var droppedRows = existing.Samples
            .Where(sample => !reachedSamples.Contains(sample.SampleKey))
            .Where(sample => !(CohortRegistryAdmission.IsPlaceholder(sample) && reachedRuns.Contains(RunIdentity(sample))))
            .Where(sample => !IsRetractable(sample))
            .OrderBy(sample => sample.SampleKey, StringComparer.Ordinal)
            .ToList();
        if (droppedRows.Count > 0)
        {
            var named = string.Join(
                "; ",
                droppedRows.Take(8).Select(sample =>
                    $"pull request {sample.PullRequestId.ToString(CultureInfo.InvariantCulture)} from cohort '{sample.CohortId}' " +
                    $"entry '{sample.EntryId}' (run root '{sample.RunRoot}')"));
            throw new ContractException(
                $"The registry at '{registryPath}' holds {droppedRows.Count.ToString(CultureInfo.InvariantCulture)} run(s) that this rebuild " +
                $"did not reach: {named}. A subject reached by a different run is not the same evidence, and an account that quietly forgot " +
                "what else had happened to a pull request would report a history it cannot support. Name every root it accounts for.");
        }

        var droppedDefects = existing.Defects
            .Where(defect => !WasNamedAgain(defect.Source))
            .OrderBy(defect => defect.Source, StringComparer.Ordinal)
            .ToList();
        if (droppedDefects.Count > 0)
        {
            var named = string.Join("; ", droppedDefects.Take(8).Select(defect => $"'{defect.Source}'"));
            throw new ContractException(
                $"The registry at '{registryPath}' records {droppedDefects.Count.ToString(CultureInfo.InvariantCulture)} defective root(s) " +
                $"that this rebuild did not name: {named}. A defect is the record of a root that was read and refused, or one nobody could " +
                "read at all, and dropping it would make the account look complete without becoming complete. Name those roots again - " +
                "repaired or not - or rebuild to a new path and reconcile the two deliberately.");
        }
    }

    /// <summary>
    /// Keeps at most one counting sample per subject, in a deterministic order.
    /// </summary>
    /// <remarks>
    /// Two roots that both qualify over one pull request are two runs of the same
    /// subject; the first in registry order occupies it and the rest become the
    /// diagnostic history the account is also for. Which one is 'first' is settled
    /// by the same ordering the registry file itself uses, so two rebuilds over the
    /// same roots elect the same sample and produce the same digest.
    /// </remarks>
    private static void SettleOneCountingSamplePerSubject(List<CohortRegistrySample> samples, List<(string Kind, string Source, string Reason)> defects)
    {
        // Total, so the order does not depend on the order the caller named their
        // roots in and List<T>.Sort's instability cannot decide anything. Two rows
        // sharing a sample key are collapsed next, and a row's own digest breaks the
        // last tie between two that disagree.
        samples.Sort((left, right) =>
        {
            var bySubject = string.CompareOrdinal(left.SubjectKey, right.SubjectKey);
            if (bySubject != 0)
            {
                return bySubject;
            }
            var byKey = string.CompareOrdinal(left.SampleKey, right.SampleKey);
            return byKey != 0
                ? byKey
                : string.CompareOrdinal(
                    left.Describe().GetText("sampleSha256"),
                    right.Describe().GetText("sampleSha256"));
        });

        // One run read twice is one sample. A caller who names a root and a
        // mirror of the same root - a pre-resume backup, a copied directory - has
        // named one run, and the sample key says so: it is derived from the
        // cohort, the entry and the audit digest, all of which a copy preserves.
        // Collapsing them here rather than refusing keeps a rebuild usable over
        // the roots an operator actually has, and the collapse is only silent
        // when the two rows agree about what happened.
        var kept = new Dictionary<string, CohortRegistrySample>(StringComparer.Ordinal);
        var settled = new List<CohortRegistrySample>(samples.Count);
        var conflicted = new HashSet<string>(StringComparer.Ordinal);
        foreach (var sample in samples)
        {
            if (kept.TryGetValue(sample.SampleKey, out var first))
            {
                if (!string.Equals(first.Describe().GetText("sampleSha256"), sample.Describe().GetText("sampleSha256"), StringComparison.Ordinal))
                {
                    defects.Add((
                        CohortRegistryDefectKinds.Unreadable,
                        sample.RunRoot,
                        $"two roots produced sample {sample.SampleKey} with different contents; the first in registry order was kept"));
                    // Neither of them can count. One sample key naming two different
                    // runs means at least one of the two roots is not what it claims,
                    // and choosing the one that happened to be named first would let
                    // an arbitrary argv order decide what the account asserts. The
                    // subject is still held - by a row that says plainly that what
                    // happened to it is not known.
                    conflicted.Add(sample.SampleKey);
                }
                continue;
            }
            kept.Add(sample.SampleKey, sample);
            settled.Add(sample);
        }
        samples.Clear();
        samples.AddRange(settled);

        // A row whose key names two disagreeing runs is demoted before anything is
        // settled, so it can neither count nor be settled around.
        for (var index = 0; index < samples.Count; index++)
        {
            var sample = samples[index];
            if (conflicted.Contains(sample.SampleKey))
            {
                samples[index] = sample with
                {
                    CountsTowardThreshold = false,
                    Classification = CohortRegistryClassifications.EvidenceUnreadable
                };
            }
        }

        // A subject is claimed by the first row that qualified for it, in registry
        // order; a later qualifying row over the same subject is a repeat.
        var occupied = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < samples.Count; index++)
        {
            var sample = samples[index];
            if (!sample.CountsTowardThreshold)
            {
                continue;
            }
            if (!occupied.Add(sample.SubjectKey))
            {
                samples[index] = sample with
                {
                    CountsTowardThreshold = false,
                    Classification = CohortRegistryClassifications.DiagnosticRepeat
                };
            }
        }

        // And a row that qualified is still a repeat when some OTHER run already put
        // this pull request in front of the models. A run that completed under a
        // refused contract, or ended over its ceiling, or ended with evidence nobody
        // could read, did not qualify - but it did observe, and a second look at work
        // this toolkit has already seen is not a second independent observation, which
        // is the whole reason the account is counted in distinct subjects. Runs that
        // observed nothing do not claim anything, and a run the operator declared as a
        // repeat - diagnostic mode, or a row demoted for repeating - does not evict the
        // row it repeats: only a run that was meant to be the observation demotes.
        //
        // Refused-contract rows are read from a manifest and no audit at all, so their
        // model-start counter is a zero this build declined to read. Deciding they
        // observed nothing on the strength of that zero is exactly how a pull request
        // reviewed under v2 and re-run under v3 would come back as a fresh subject.
        var observed = samples
            .Where(sample => !sample.CountsTowardThreshold
                && CohortRegistryClassifications.IsPriorObservation(sample.Classification, sample.RealModelStarts))
            .Select(sample => sample.SubjectKey)
            .ToHashSet(StringComparer.Ordinal);
        for (var index = 0; index < samples.Count; index++)
        {
            var sample = samples[index];
            if (sample.CountsTowardThreshold && observed.Contains(sample.SubjectKey))
            {
                samples[index] = sample with
                {
                    CountsTowardThreshold = false,
                    Classification = CohortRegistryClassifications.DiagnosticRepeat
                };
            }
        }
    }

    /// <summary>
    /// The paths one named cohort owns: its journal root and its entries' output
    /// roots, read leniently.
    /// </summary>
    /// <remarks>
    /// Lenient on purpose. This runs before the manifest is read as a contract, and
    /// its only job is to say which defect sources this cohort is entitled to offer
    /// for re-reading. A manifest too damaged to yield its roots simply contributes
    /// none, and the defects raised inside it then have to be named exactly - which
    /// is the strict direction.
    /// </remarks>
    private static void CollectOwnedScopes(string manifestPath, List<string> scopes)
    {
        try
        {
            var bytes = StrictJson.ReadFileBytes(manifestPath, "cohort manifest");
            var root = StrictJson.ReadObjectBytes(bytes, manifestPath, "cohort manifest");
            var manifestDirectory = Path.GetDirectoryName(Path.GetFullPath(manifestPath));
            if (root.TryGetProperty("journal", out var journal)
                && journal.ValueKind == JsonValueKind.Object
                && journal.TryGetProperty("root", out var journalRoot)
                && journalRoot.ValueKind == JsonValueKind.String)
            {
                AddScope(journalRoot.GetString(), manifestDirectory, scopes);
            }
            if (!root.TryGetProperty("entries", out var entries) || entries.ValueKind != JsonValueKind.Array)
            {
                return;
            }
            foreach (var entry in entries.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.Object
                    || !entry.TryGetProperty("output", out var output)
                    || output.ValueKind != JsonValueKind.Object
                    || !output.TryGetProperty("root", out var outputRoot)
                    || outputRoot.ValueKind != JsonValueKind.String)
                {
                    continue;
                }
                AddScope(outputRoot.GetString(), manifestDirectory, scopes);
            }
        }
        catch (Exception error) when (error is ContractException or IOException or UnauthorizedAccessException)
        {
            // Nothing to add. The strict read that follows will say why.
        }
    }

    private static void AddScope(string? declared, string? manifestDirectory, List<string> scopes)
    {
        if (string.IsNullOrWhiteSpace(declared))
        {
            return;
        }
        try
        {
            var resolved = Path.IsPathRooted(declared) || manifestDirectory is null
                ? Path.GetFullPath(declared)
                : Path.GetFullPath(Path.Combine(manifestDirectory, declared));
            scopes.Add(resolved);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            // A root this build cannot even resolve to a path scopes nothing.
        }
    }

    private static void ReadCohort(
        string manifestPath,
        List<CohortRegistrySample> samples,
        List<(string Kind, string Source, string Reason)> defects,
        List<string> cleared,
        TextWriter log)
    {
        if (!File.Exists(manifestPath))
        {
            throw new ContractException("there is no manifest at that path");
        }
        var contractVersion = PeekContractVersion(manifestPath);
        if (string.Equals(contractVersion, CohortManifest.ContractVersionValue, StringComparison.Ordinal))
        {
            ReadCurrentCohort(manifestPath, samples, defects, cleared, log);
            return;
        }
        ReadRefusedContractCohort(manifestPath, contractVersion, samples, defects, log);
    }

    /// <summary>The declared contract version, read from the bytes and nothing else.</summary>
    private static string PeekContractVersion(string manifestPath)
    {
        var bytes = StrictJson.ReadFileBytes(manifestPath, "cohort manifest");
        var root = StrictJson.ReadObjectBytes(bytes, manifestPath, "cohort manifest");
        if (!root.TryGetProperty("contractVersion", out var declared) || declared.ValueKind != JsonValueKind.String)
        {
            throw new ContractException("the manifest declares no string 'contractVersion', so what it is cannot be decided");
        }
        return declared.GetString() ?? string.Empty;
    }

    /// <summary>
    /// Reads a root declared under the contract this build runs, through the same
    /// readers a run uses.
    /// </summary>
    private static void ReadCurrentCohort(
        string manifestPath,
        List<CohortRegistrySample> samples,
        List<(string Kind, string Source, string Reason)> defects,
        List<string> cleared,
        TextWriter log)
    {
        var manifest = CohortManifest.Load(manifestPath);
        if (!File.Exists(manifest.JournalPath) || !File.Exists(manifest.JournalKeyPath))
        {
            // No journal means no committed intent, no authorization, and no digest
            // to hold any entry's artifacts to - the journal, with its prelaunch
            // intent, is written and signed BEFORE any child starts. So nothing this
            // root did can be asserted, whether it launched nothing or launched
            // everything and lost its record.
            //
            // Every declared subject is therefore held by a row that counts toward
            // nothing. The tempting refinement - free the ones whose output root holds
            // no coordinator directory, since that is where a child's state lives and
            // no state means no model - reads the file system as though it were
            // evidence. It is not: the runner's own child creates that output root
            // before it writes anything into it, an operator may have made it by hand,
            // and deleting just the coordinator directory looks identical to never
            // having written one. With no signed journal to hold any of it to, absence
            // proves nothing in either direction, and the account is not the place to
            // guess. Only an authenticated journal saying an entry is still pending
            // frees a subject.
            //
            // The defect is 'noted' rather than 'unreadable': the account is not left
            // with an open question, it is left with an answer.
            foreach (var entry in manifest.Entries)
            {
                samples.Add(CohortRegistryAdmission.UnlaunchedSampleFor(manifest, entry));
                log.WriteLine(
                    $"{manifestPath}: entry '{entry.EntryId}' pr={entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} " +
                    "has no surviving cohort journal and nothing that can rule out a spend; subject held, counts=false.");
            }
            defects.Add((
                CohortRegistryDefectKinds.Noted,
                manifestPath,
                $"committed no signed journal at '{manifest.JournalRoot}', so what it ran cannot be asserted; " +
                $"all {manifest.Entries.Count.ToString(CultureInfo.InvariantCulture)} " +
                "declared entries are held by rows that count toward nothing"));
            return;
        }

        // Read, never minted. A rebuild that minted a key into someone's finished
        // root would be writing into the immutable evidence it came to read.
        var key = CohortJournal.LoadOrMintKey(manifest, out var keyPreexisted);
        if (!keyPreexisted)
        {
            throw new ContractException($"the cohort journal key at '{manifest.JournalKeyPath}' was not there to read");
        }
        var journal = CohortJournal.LoadOrFresh(manifest, key, keyPreexisted);

        var spent = CohortRegistryAdmission.Spent.Nothing;
        foreach (var entry in manifest.Entries)
        {
            var record = journal.RecordFor(entry.EntryId);
            if (record.EndedRefused)
            {
                // A refused ending commits no audit digest - there was no audit this
                // build could read - so holding its artifacts to a committed digest
                // would fail forever, on evidence that is immutable and correct. The
                // refusal is a CLOSED fact, not an open question: the entry ran, its
                // evidence was refused, and that is exactly what is recorded. Noted
                // rather than unreadable, so an old refusal does not lock the account
                // out of counting for good.
                defects.Add((
                    CohortRegistryDefectKinds.Noted,
                    entry.OutputRoot,
                    $"entry '{entry.EntryId}' ended with its published evidence refused, so what it ran cannot be summarized"));
                samples.Add(CohortRegistryAdmission.UnreadableSampleFor(
                    manifest with { Registry = CountingBindingFor(manifest, entry) },
                    entry,
                    record,
                    ReadAuthorizedByOrUnknown(manifest, entry, record)));
                log.WriteLine($"{manifestPath}: entry '{entry.EntryId}' evidence refused; subject held, counts=false.");
                spent = spent with
                {
                    ModelStarts = spent.ModelStarts + record.ModelStartCount + record.ModelStartUnmeasuredAllowance,
                    VerifierAssignments = spent.VerifierAssignments + record.VerifierAssignmentCount + record.VerifierAssignmentUnmeasuredAllowance,
                    WallClockSeconds = spent.WallClockSeconds + record.ElapsedSeconds
                };
                continue;
            }
            if (!record.HasEnded)
            {
                if (record.HasOpenLaunch)
                {
                    // A committed launch intent, or a child recorded as running, and
                    // no ending. The intent is written and signed BEFORE the child
                    // starts, so this entry either spent its subject or was a moment
                    // away from doing so, and nothing on disk can tell the two apart.
                    // Held, counting toward nothing: freeing a pull request that a
                    // crashed run may have put in front of the models is the one
                    // mistake this account exists to prevent.
                    defects.Add((
                        CohortRegistryDefectKinds.Noted,
                        entry.OutputRoot,
                        $"entry '{entry.EntryId}' has a committed launch and no ending, so whether it ran cannot be decided"));
                    samples.Add(CohortRegistryAdmission.UnreadableSampleFor(
                        manifest with { Registry = CountingBindingFor(manifest, entry) },
                        entry,
                        record,
                        ReadAuthorizedByOrUnknown(manifest, entry, record)));
                    log.WriteLine($"{manifestPath}: entry '{entry.EntryId}' launched and never ended; subject held, counts=false.");
                    continue;
                }
                // Pending or blocked: no launch was ever committed, so no child ever
                // started and the subject was never occupied. The account says
                // nothing about it rather than something wrong - and this is the one
                // reading that can CLEAR a hold placed on this entry by an earlier,
                // less informed rebuild, because it is the only one backed by an
                // authenticated journal saying the launch never happened.
                cleared.Add(
                    manifest.CohortId + "\u001f" + entry.EntryId + "\u001f" + CohortRegistry.SubjectKeyOf(entry)
                    + "\u001f" + manifest.ManifestSha256);
                log.WriteLine($"{manifestPath}: entry '{entry.EntryId}' never launched; no sample recorded.");
                continue;
            }

            CohortEntrySummary summary;
            string authorizedBy;
            try
            {
                summary = CohortSummaryReader.Read(entry, record, record.ElapsedSeconds, ReadEntryCorrelation(entry));
                // The journal committed digests for exactly these artifacts when the
                // entry ended. Re-scoring an audit that no longer matches them would
                // let a swapped file decide what the account asserts, which is the
                // one thing a rebuild that trusts no summary must not do.
                CohortRunner.RequireCommittedDigests(entry, record, summary);
                authorizedBy = ReadAuthorizedBy(manifest, entry, record);
            }
            catch (Exception error) when (error is ContractException or CohortBlockedException or IOException or UnauthorizedAccessException)
            {
                // The entry ended, so its subject was spent. What it did is now
                // unreadable - and a subject whose fate cannot be read must not fall
                // back to being free. Hold it with a row that counts toward nothing
                // and says exactly that, and file the defect.
                //
                // 'noted', not 'unreadable'. The two kinds do not grade how bad a root
                // is; they say whether the account is left with an open QUESTION.
                // Here the journal named the exact subject that was spent and the row
                // above holds it, so coverage is known and settled - what is missing is
                // detail about one run, not the possibility of an unaccounted spend.
                // Filing it as unreadable would fail every unrelated counting cohort
                // closed, machine-wide, over a root that cannot hand out a pull request
                // twice. 'unreadable' stays for roots that could not be read far enough
                // to say WHICH subjects they touched.
                defects.Add((
                    CohortRegistryDefectKinds.Noted,
                    entry.OutputRoot,
                    $"entry '{entry.EntryId}' ended and its evidence cannot be read: {error.Message}"));
                samples.Add(CohortRegistryAdmission.UnreadableSampleFor(
                    manifest with { Registry = CountingBindingFor(manifest, entry) },
                    entry,
                    record,
                    ReadAuthorizedByOrUnknown(manifest, entry, record)));
                log.WriteLine($"{manifestPath}: entry '{entry.EntryId}' evidence unreadable; subject held, counts=false.");
                spent = spent with
                {
                    ModelStarts = spent.ModelStarts + record.ModelStartCount + record.ModelStartUnmeasuredAllowance,
                    VerifierAssignments = spent.VerifierAssignments + record.VerifierAssignmentCount + record.VerifierAssignmentUnmeasuredAllowance,
                    WallClockSeconds = spent.WallClockSeconds + record.ElapsedSeconds
                };
                continue;
            }
            // Never "already held" here. Which of several qualifying runs over one
            // subject occupies it is decided once, by the settle pass, against the
            // registry's own ordering - so the answer does not depend on the order
            // the caller happened to name their roots in.
            var sample = CohortRegistryAdmission.SampleFor(
                manifest with { Registry = CountingBindingFor(manifest, entry) },
                entry,
                summary,
                record.Outcome,
                authorizedBy,
                false,
                record.EndedAtUtc,
                spent);
            // The ceilings are the cohort's, so what came before is carried forward
            // exactly as the runner carried it: ended entries only, actuals plus the
            // allowance nothing measured.
            spent = spent with
            {
                ModelStarts = spent.ModelStarts + record.ModelStartCount + record.ModelStartUnmeasuredAllowance,
                VerifierAssignments = spent.VerifierAssignments + record.VerifierAssignmentCount + record.VerifierAssignmentUnmeasuredAllowance,
                WallClockSeconds = spent.WallClockSeconds + record.ElapsedSeconds
            };
            samples.Add(sample);
            log.WriteLine(
                $"{manifestPath}: entry '{entry.EntryId}' pr={entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} " +
                $"classified '{sample.Classification}' counts={(sample.CountsTowardThreshold ? "true" : "false")} " +
                $"modelStarts={sample.RealModelStarts.ToString(CultureInfo.InvariantCulture)} " +
                $"verifierAssignments={sample.RealVerifierAssignments.ToString(CultureInfo.InvariantCulture)} " +
                $"providerWrites={sample.ProviderWrites.ToString(CultureInfo.InvariantCulture)}");
        }
    }

    /// <summary>
    /// The binding a rebuild classifies against.
    /// </summary>
    /// <remarks>
    /// A finished root may bind no registry at all - most of them predate this
    /// account - and refusing to classify those would leave the reach unknowable.
    /// What the binding contributes to a classification is the MODE, and a rebuild
    /// asks the counting question of every root it reads: 'may this run occupy its
    /// subject'. A root that ran in diagnostic mode said so in its own binding, and
    /// that binding is honoured.
    /// </remarks>
    private static CohortRegistryBinding CountingBindingFor(CohortManifest manifest, CohortEntry entry) =>
        manifest.Registry ?? new CohortRegistryBinding
        {
            Path = manifest.IndexPath,
            Sha256 = CohortRegistryBinding.UnstartedRegistry,
            TargetSubjectKey = CohortRegistry.SubjectKeyOf(entry),
            Mode = CohortRegistryModes.Count
        };

    /// <summary>
    /// The correlation the entry's own sealed request declares, read from the file
    /// the manifest pinned.
    /// </summary>
    private static string ReadEntryCorrelation(CohortEntry entry)
    {
        var label = $"entry '{entry.EntryId}' request";
        var bytes = StrictJson.ReadFileBytes(entry.RequestPath, label);
        var digest = CanonicalJson.Sha256Hex(bytes);
        if (!string.Equals(digest, entry.RequestSha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"entry '{entry.EntryId}' pins a request digesting to {entry.RequestSha256} and the file at '{entry.RequestPath}' " +
                $"digests to {digest}; the root is not the root that was declared");
        }
        var root = StrictJson.ReadObjectBytes(bytes, entry.RequestPath, label);
        return StrictJson.RequireString(root, "correlationId", label);
    }

    /// <summary>
    /// The operator alias the run was started under, taken from the launch intent
    /// the signed journal pins by digest.
    /// </summary>
    /// <remarks>
    /// Not read from the published index, which is a document the run wrote about
    /// itself. The journal is signed and records the digest of the exact intent it
    /// committed; the intent carries the alias. Re-digesting the intent and
    /// comparing it to the journal's is what turns an ordinary file into evidence.
    /// </remarks>
    internal static string ReadAuthorizedBy(CohortManifest manifest, CohortEntry entry, CohortEntryRecord record)
    {
        var path = Path.Combine(
            manifest.IntentRoot,
            entry.EntryId + ".attempt" + record.Attempt.ToString(CultureInfo.InvariantCulture) + ".intent.json");
        var label = $"entry '{entry.EntryId}' launch intent";
        if (!File.Exists(path))
        {
            if (!string.Equals(record.IntentSha256, "none", StringComparison.Ordinal))
            {
                // The journal committed an intent and pinned its digest, so an
                // authorization DID exist and the file that carried it is gone.
                // Returning 'none' here would file destroyed evidence under the same
                // word as evidence that never existed, and an operator reading the
                // account could not tell the two apart.
                throw new ContractException(
                    $"entry '{entry.EntryId}' has a signed journal pinning intent {record.IntentSha256} and there is no intent at " +
                    $"'{path}'; the authorization it committed cannot be read");
            }
            // An entry that ended without a committed intent never launched a
            // child - a refusal before preparation, for instance. It has no
            // authorization to read, and 'none' is the honest reading: it cannot
            // count, and the classification will say why.
            return "none";
        }
        var bytes = StrictJson.ReadFileBytes(path, label);
        var root = StrictJson.ReadObjectBytes(bytes, path, label);
        // Digested the way the runner digested it: over the CANONICAL form, not
        // over the readable bytes on disk. The runner writes the intent indented
        // for a human and pins the canonical digest in the journal, so comparing
        // raw file bytes would refuse every honest intent ever written.
        var digest = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(Node.FromJson(root, label)));
        if (!string.Equals(digest, record.IntentSha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"entry '{entry.EntryId}' has a signed journal pinning intent {record.IntentSha256} and the intent at '{path}' digests " +
                $"to {digest}; the authorization on disk is not the authorization that was committed");
        }
        return StrictJson.RequireString(root, "authorizedBy", label);
    }

    /// <summary>
    /// The authorization on an entry whose evidence is already known to be
    /// unreadable, which must not fail a second time on the way to saying so.
    /// </summary>
    internal static string ReadAuthorizedByOrUnknown(CohortManifest manifest, CohortEntry entry, CohortEntryRecord record)
    {
        try
        {
            return ReadAuthorizedBy(manifest, entry, record);
        }
        catch (Exception error) when (error is ContractException or IOException or UnauthorizedAccessException)
        {
            return "none";
        }
    }

    /// <summary>
    /// Records the identity of a root this build refuses to run, without pretending
    /// to have read what it spent.
    /// </summary>
    /// <remarks>
    /// The v1 and v2 contracts declared their budgets in units that undercounted -
    /// a cycle count read as model starts, a terminal count read as verifier
    /// assignments - so a run under them cannot occupy a subject however clean it
    /// looks. What it CAN do is tell an operator that the pull request was used,
    /// which is why the identity is read leniently and the counters are not read at
    /// all: reading them through a lenient parser would produce numbers with no
    /// signature behind them, and an unsigned number in a signed account is worse
    /// than no number.
    /// </remarks>
    private static void ReadRefusedContractCohort(
        string manifestPath,
        string contractVersion,
        List<CohortRegistrySample> samples,
        List<(string Kind, string Source, string Reason)> defects,
        TextWriter log)
    {
        var bytes = StrictJson.ReadFileBytes(manifestPath, "cohort manifest");
        var manifestSha256 = CanonicalJson.Sha256Hex(bytes);
        var root = StrictJson.ReadObjectBytes(bytes, manifestPath, "cohort manifest");
        var cohortId = TextOr(root, "cohortId", "unknown");
        var toolkitHead = root.TryGetProperty("toolkit", out var toolkit) && toolkit.ValueKind == JsonValueKind.Object
            ? TextOr(toolkit, "head", "unknown")
            : "unknown";

        if (!root.TryGetProperty("entries", out var entries) || entries.ValueKind != JsonValueKind.Array)
        {
            throw new ContractException($"declared under '{contractVersion}', which this build refuses, and its entries could not be read either");
        }

        var ordinal = 0;
        foreach (var entryNode in entries.EnumerateArray())
        {
            ordinal++;
            if (entryNode.ValueKind != JsonValueKind.Object
                || !entryNode.TryGetProperty("subject", out var subject)
                || subject.ValueKind != JsonValueKind.Object)
            {
                defects.Add((CohortRegistryDefectKinds.Unreadable, manifestPath, $"entry {ordinal.ToString(CultureInfo.InvariantCulture)} declares no readable subject"));
                continue;
            }
            // The subject key is what the account is FOR. Synthesizing 'unknown' into
            // it would mint a key that holds nothing, leave the real pull request
            // selectable, and look on the page exactly like a row that had been read.
            var organization = TextOr(subject, "organization", string.Empty);
            var project = TextOr(subject, "project", string.Empty);
            var repository = TextOr(subject, "repository", string.Empty);
            if (organization.Length == 0 || project.Length == 0 || repository.Length == 0)
            {
                defects.Add((
                    CohortRegistryDefectKinds.Unreadable,
                    manifestPath,
                    $"entry {ordinal.ToString(CultureInfo.InvariantCulture)} declares no readable repository identity"));
                continue;
            }
            var repositoryId = string.Join('/', organization, project, repository);
            var pullRequestId = IntOr(subject, "pullRequestId", 0);
            if (pullRequestId <= 0)
            {
                defects.Add((CohortRegistryDefectKinds.Unreadable, manifestPath, $"entry {ordinal.ToString(CultureInfo.InvariantCulture)} declares no readable pull request id"));
                continue;
            }
            var entryId = TextOr(entryNode, "entryId", "entry" + ordinal.ToString(CultureInfo.InvariantCulture));
            var subjectKey = CohortRegistry.SubjectKeyOf(repositoryId, pullRequestId);
            samples.Add(new CohortRegistrySample
            {
                SubjectKey = subjectKey,
                // Keyed on the manifest digest rather than an audit digest, because
                // no audit was read. Two rebuilds over the same root produce the
                // same key; a different root over the same subject produces another.
                SampleKey = CohortRegistry.SampleKeyOf(subjectKey, cohortId, entryId, manifestSha256),
                RepositoryId = repositoryId,
                PullRequestId = pullRequestId,
                IterationId = IntOr(subject, "iterationId", 0),
                SourceCommit = TextOr(subject, "sourceCommit", "unknown"),
                TargetRefName = TextOr(subject, "targetRefName", "unknown"),
                RunRoot = TextOr(entryNode, "outputRoot", "unknown"),
                ManifestContractVersion = contractVersion,
                ManifestSha256 = manifestSha256,
                ToolkitHead = toolkitHead,
                CohortId = cohortId,
                EntryId = entryId,
                AuthorizationKind = "unknown",
                AuthorizedBy = "none",
                TerminalState = "unknown",
                TerminalOutcome = "unknown",
                RealModelStarts = 0,
                RealVerifierAssignments = 0,
                ProviderWrites = 0,
                WriteToolInvocations = 0,
                WallClockSeconds = 0,
                CensusComplete = false,
                BudgetCompliant = false,
                AuditSha256 = manifestSha256,
                // No signed record of when this run ended was read, and the clock
                // is not evidence. 'none' keeps the row deterministic across
                // rebuilds and says plainly that the time is not known.
                ObservedAtUtc = "none",
                CountsTowardThreshold = false,
                Classification = CohortRegistryClassifications.UnsafeBudgetContract
            });
            log.WriteLine(
                $"{manifestPath}: entry '{entryId}' pr={pullRequestId.ToString(CultureInfo.InvariantCulture)} declared under " +
                $"'{contractVersion}'; recorded as history that cannot count.");
        }

        defects.Add((
            CohortRegistryDefectKinds.Noted,
            manifestPath,
            $"declared under '{contractVersion}', whose budget units this build refuses; its subjects are recorded as history and cannot count"));
    }

    private static string TextOr(JsonElement node, string name, string fallback) =>
        node.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? fallback
            : fallback;

    private static int IntOr(JsonElement node, string name, int fallback) =>
        node.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetInt32(out var parsed)
            ? parsed
            : fallback;
}
