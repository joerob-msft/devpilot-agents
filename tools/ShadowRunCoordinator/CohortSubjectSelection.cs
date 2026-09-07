using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Chooses the next subjects to run from a caller-supplied candidate list, with
/// every subject the account already holds removed.
/// </summary>
/// <remarks>
/// This exists so that 'which pull requests have already been used' stops being a
/// sentence someone types. The exclusion is derived from the signed registry and
/// nothing else: a candidate is dropped because the account holds a sample over
/// its subject, and the selection names the revision it was derived from so the
/// answer can be re-checked later.
///
/// A sample that does not count still excludes. The account holds diagnostic
/// history for a reason - a subject that has been run before is a subject whose
/// next run is not a fresh observation - and a helper that offered it again would
/// quietly reintroduce the repeat this whole account exists to notice. An operator
/// who wants the repeat declares it, in a manifest, in diagnostic mode.
///
/// It selects and writes a file. It does not run anything, and it cannot: nothing
/// here launches a process or reaches a network.
/// </remarks>
internal static class CohortSubjectSelection
{
    internal const string CandidateContractVersion = "devpilot.shadow-cohort.candidates.v1";
    internal const string CandidateKind = "shadow-cohort-candidates";
    internal const string SelectionContractVersion = "devpilot.shadow-cohort.selection.v1";
    internal const string SelectionKind = "shadow-cohort-selection";

    internal static int Run(
        string registryPath,
        string candidatesPath,
        int count,
        string outputPath,
        bool acceptUnresolvedDefects,
        bool acceptUnstartedRegistry,
        TextWriter log)
    {
        var key = CohortRegistry.LoadOrMintKey(registryPath, out var keyPreexisted);
        var registry = CohortRegistry.LoadOrFresh(registryPath, key, keyPreexisted);
        if (!File.Exists(registryPath))
        {
            // An account file that is not there is almost always a mistyped path, and
            // this is the one command where that mistake is silent and expensive: an
            // empty account excludes nothing, so the answer is the head of the
            // candidate list - pull requests that may every one of them have been spent
            // already. The rebuild refuses a root that is not there for the same
            // reason; a selection that ANSWERS where a rebuild would refuse is the
            // worse of the two. Starting genuinely fresh is a real case, so it is
            // allowed, but only when the operator says so and it is written into the
            // selection for whoever reads it next.
            if (!acceptUnstartedRegistry)
            {
                throw new ContractException(
                    $"There is no registry at '{Path.GetFullPath(registryPath)}'. An account that does not exist excludes nothing, so this " +
                    "selection would hand back the first candidates on the list whether or not they have already been spent. Check the path, " +
                    "or pass --accept-unstarted-registry to select against a genuinely empty account and have that recorded in the selection.");
            }
            log.WriteLine($"registry {registryPath} does not exist yet; nothing is excluded (accepted by the caller).");
        }

        // A defect of kind 'unreadable' is a root the account could not read, and a root
        // nobody could read may hold any subject at all - including one on the candidate
        // list. Choosing from an account with unread evidence in it is choosing from an
        // exclusion list that is known to be incomplete, so it stops here rather than
        // handing back an answer whose confidence it cannot support. A 'noted' defect is
        // a root that WAS read in full and merely does not qualify to count; it excludes
        // its subjects like any other row and leaves no question open, so it does not
        // stop anything. The override exists because an operator sometimes knows what the
        // unreadable root was, and it is written into the selection so the next reader
        // knows it was used.
        var unreadable = registry.Defects
            .Where(defect => string.Equals(defect.Kind, CohortRegistryDefectKinds.Unreadable, StringComparison.Ordinal))
            .ToList();
        if (unreadable.Count > 0 && !acceptUnresolvedDefects)
        {
            var named = string.Join(
                "; ",
                unreadable.Take(8).Select(defect => $"'{defect.Source}' ({defect.Reason})"));
            throw new ContractException(
                $"The registry at '{Path.GetFullPath(registryPath)}' records " +
                $"{unreadable.Count.ToString(CultureInfo.InvariantCulture)} root(s) it could not read: {named}. Any of them may hold a " +
                "subject on this candidate list, so the exclusion is known to be incomplete and a selection made from it would look more " +
                "certain than it is. Repair or re-name those roots and rebuild, or pass --accept-unresolved-defects to choose anyway and " +
                "have that recorded in the selection.");
        }

        var candidates = ReadCandidates(candidatesPath);
        var selected = new ListNode();
        var excluded = new ListNode();
        var chosen = 0;
        foreach (var candidate in candidates)
        {
            var subjectKey = CohortRegistry.SubjectKeyOf(candidate.RepositoryId, candidate.PullRequestId);
            var held = registry.AnySampleFor(subjectKey);
            if (held is not null)
            {
                excluded.Add(candidate.Describe(subjectKey)
                    .Set("reason", "the account already holds this subject")
                    .Set("heldByCohortId", held.CohortId)
                    .Set("heldClassification", held.Classification)
                    .Set("heldCountsTowardThreshold", held.CountsTowardThreshold));
                continue;
            }
            if (chosen >= count)
            {
                excluded.Add(candidate.Describe(subjectKey)
                    .Set("reason", "eligible, and beyond the requested count")
                    .Set("heldByCohortId", "none")
                    .Set("heldClassification", "none")
                    .Set("heldCountsTowardThreshold", false));
                continue;
            }
            selected.Add(candidate.Describe(subjectKey));
            chosen++;
        }

        var body = new MapNode()
            .Set("contractVersion", SelectionContractVersion)
            .Set("kind", SelectionKind)
            .Set("registryPath", Path.GetFullPath(registryPath))
            .Set("registrySha256", registry.RegistrySha256)
            .Set("registryRevision", registry.Revision)
            .Set("candidatesPath", Path.GetFullPath(candidatesPath))
            .Set("requestedCount", count)
            .Set("selectedCount", chosen)
            .Set("countedSubjectsOnRecord", registry.CountingSampleCount)
            .Set("distinctSubjectsOnRecord", registry.DistinctSubjectCount)
            .Set("unresolvedDefectCount", unreadable.Count)
            .Set("notedDefectCount", registry.Defects.Count - unreadable.Count)
            .Set("acceptedUnresolvedDefects", acceptUnresolvedDefects)
            .Set("acceptedUnstartedRegistry", acceptUnstartedRegistry)
            .Set("selectedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture))
            .Set("selected", selected)
            .Set("excluded", excluded);
        body.Set("selectionSha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(body)));
        var parent = Path.GetDirectoryName(Path.GetFullPath(outputPath));
        if (!string.IsNullOrEmpty(parent))
        {
            Directory.CreateDirectory(parent);
        }
        CanonicalJson.WriteFileAtomic(outputPath, CanonicalJson.Readable(body));

        log.WriteLine(
            $"selection {outputPath}: {chosen.ToString(CultureInfo.InvariantCulture)} of " +
            $"{count.ToString(CultureInfo.InvariantCulture)} requested chosen from " +
            $"{candidates.Count.ToString(CultureInfo.InvariantCulture)} candidate(s), against registry revision " +
            $"{registry.Revision.ToString(CultureInfo.InvariantCulture)} ({registry.RegistrySha256}).");
        if (chosen < count)
        {
            log.WriteLine(
                $"the candidate list did not hold {count.ToString(CultureInfo.InvariantCulture)} unspent subject(s); " +
                "supply more candidates rather than reusing one.");
        }
        if (unreadable.Count > 0)
        {
            log.WriteLine(
                $"{unreadable.Count.ToString(CultureInfo.InvariantCulture)} root(s) in the account could not be read, and this " +
                "selection was made anyway on the caller's instruction; the exclusion may be incomplete.");
        }
        return CoordinatorExitCodes.Ok;
    }

    private sealed record Candidate(
        string Organization,
        string Project,
        string Repository,
        int PullRequestId,
        int IterationId,
        string SourceCommit,
        string TargetRefName)
    {
        internal string RepositoryId => Organization + "/" + Project + "/" + Repository;

        internal MapNode Describe(string subjectKey) => new MapNode()
            .Set("subjectKey", subjectKey)
            .Set("organization", Organization)
            .Set("project", Project)
            .Set("repository", Repository)
            .Set("pullRequestId", PullRequestId)
            .Set("iterationId", IterationId)
            .Set("sourceCommit", SourceCommit)
            .Set("targetRefName", TargetRefName);
    }

    private static List<Candidate> ReadCandidates(string candidatesPath)
    {
        const string label = "cohort candidate list";
        var bytes = StrictJson.ReadFileBytes(candidatesPath, label);
        var root = StrictJson.ReadObjectBytes(bytes, candidatesPath, label);
        StrictJson.RequireNoUnknownFields(root, label, "contractVersion", "kind", "candidates");
        StrictJson.RequireLiteral(root, "contractVersion", CandidateContractVersion, label);
        StrictJson.RequireLiteral(root, "kind", CandidateKind, label);

        var candidates = new List<Candidate>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var ordinal = 0;
        foreach (var node in StrictJson.RequireArray(root, "candidates", label))
        {
            ordinal++;
            var candidateLabel = $"{label} candidate {ordinal.ToString(CultureInfo.InvariantCulture)}";
            if (node.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {candidateLabel} is {StrictJson.Describe(node.ValueKind)} rather than an object.");
            }
            StrictJson.RequireNoUnknownFields(
                node,
                candidateLabel,
                "organization",
                "project",
                "repository",
                "pullRequestId",
                "iterationId",
                "sourceCommit",
                "targetRefName");
            var candidate = new Candidate(
                StrictJson.RequireString(node, "organization", candidateLabel),
                StrictJson.RequireString(node, "project", candidateLabel),
                StrictJson.RequireString(node, "repository", candidateLabel),
                StrictJson.RequireInt(node, "pullRequestId", candidateLabel, 1, int.MaxValue),
                StrictJson.RequireInt(node, "iterationId", candidateLabel, 1, int.MaxValue),
                StrictJson.RequireString(node, "sourceCommit", candidateLabel),
                StrictJson.RequireString(node, "targetRefName", candidateLabel));
            // A list that names one subject twice would let a selection of two
            // return the same pull request twice, which is the duplicate this
            // whole account exists to stop - arriving through the front door.
            if (!seen.Add(CohortRegistry.SubjectKeyOf(candidate.RepositoryId, candidate.PullRequestId)))
            {
                throw new ContractException(
                    $"The {label} names '{candidate.RepositoryId}' pull request " +
                    $"{candidate.PullRequestId.ToString(CultureInfo.InvariantCulture)} more than once. One subject is one candidate.");
            }
            candidates.Add(candidate);
        }
        if (candidates.Count == 0)
        {
            throw new ContractException($"The {label} declares no candidates, so there is nothing to select from.");
        }
        return candidates;
    }
}
