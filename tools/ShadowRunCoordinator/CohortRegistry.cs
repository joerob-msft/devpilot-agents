using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The durable account of which subjects this toolkit has already been run over.
/// </summary>
/// <remarks>
/// A cohort journal accounts for one cohort and an index reports one cohort. Neither
/// can answer the question an operator actually has to answer before authorizing the
/// next one: has this pull request already been spent? Answering it from a list kept
/// in a prompt is answering it from memory, and memory is exactly what produced a
/// claimed count that nobody could re-derive.
///
/// So the account lives in a file, outside the repository, signed with its own key,
/// and it is written by the runner rather than by a person. It holds ONE canonical
/// sample per distinct subject - a repository identity paired with a pull request
/// number - and every other run over that same subject is kept as history that
/// cannot count. What counts and what does not is decided from the same signed
/// evidence the index is derived from, never from a summary somebody typed.
/// </remarks>
internal sealed record CohortRegistrySample
{
    /// <summary>The distinct subject this sample was taken over: one repository, one pull request.</summary>
    internal required string SubjectKey { get; init; }

    /// <summary>This sample's own identity, distinct even when the subject repeats.</summary>
    internal required string SampleKey { get; init; }

    /// <summary>The repository identity as declared, kept for a reader; the key is folded.</summary>
    internal required string RepositoryId { get; init; }

    internal required int PullRequestId { get; init; }

    internal required int IterationId { get; init; }

    internal required string SourceCommit { get; init; }

    internal required string TargetRefName { get; init; }

    /// <summary>The immutable output root this sample's evidence was read from.</summary>
    internal required string RunRoot { get; init; }

    /// <summary>The cohort contract the run was declared under. v1 and v2 cannot count.</summary>
    internal required string ManifestContractVersion { get; init; }

    internal required string ManifestSha256 { get; init; }

    internal required string ToolkitHead { get; init; }

    internal required string CohortId { get; init; }

    internal required string EntryId { get; init; }

    internal required string AuthorizationKind { get; init; }

    /// <summary>The operator alias the run was started under, or 'none' when the record does not name one.</summary>
    internal required string AuthorizedBy { get; init; }

    internal required string TerminalState { get; init; }

    internal required string TerminalOutcome { get; init; }

    internal required int RealModelStarts { get; init; }

    internal required int RealVerifierAssignments { get; init; }

    internal required int ProviderWrites { get; init; }

    internal required int WriteToolInvocations { get; init; }

    internal required int WallClockSeconds { get; init; }

    /// <summary>True when both censuses measured the whole run rather than charging a remainder.</summary>
    internal required bool CensusComplete { get; init; }

    /// <summary>True when the actual counts sat inside the ceilings the cohort declared, in the units this build spends.</summary>
    internal required bool BudgetCompliant { get; init; }

    internal required string AuditSha256 { get; init; }

    internal required string ObservedAtUtc { get; init; }

    /// <summary>The one field an operator's count is taken over.</summary>
    internal required bool CountsTowardThreshold { get; init; }

    /// <summary>Why this sample counts, or the first reason it does not.</summary>
    internal required string Classification { get; init; }

    internal MapNode Describe()
    {
        var node = new MapNode()
            .Set("subjectKey", SubjectKey)
            .Set("sampleKey", SampleKey)
            .Set("repositoryId", RepositoryId)
            .Set("pullRequestId", PullRequestId)
            .Set("iterationId", IterationId)
            .Set("sourceCommit", SourceCommit)
            .Set("targetRefName", TargetRefName)
            .Set("runRoot", RunRoot)
            .Set("manifestContractVersion", ManifestContractVersion)
            .Set("manifestSha256", ManifestSha256)
            .Set("toolkitHead", ToolkitHead)
            .Set("cohortId", CohortId)
            .Set("entryId", EntryId)
            .Set("authorizationKind", AuthorizationKind)
            .Set("authorizedBy", AuthorizedBy)
            .Set("terminalState", TerminalState)
            .Set("terminalOutcome", TerminalOutcome)
            .Set("realModelStarts", RealModelStarts)
            .Set("realVerifierAssignments", RealVerifierAssignments)
            .Set("providerWrites", ProviderWrites)
            .Set("writeToolInvocations", WriteToolInvocations)
            .Set("wallClockSeconds", WallClockSeconds)
            .Set("censusComplete", CensusComplete)
            .Set("budgetCompliant", BudgetCompliant)
            .Set("auditSha256", AuditSha256)
            .Set("observedAtUtc", ObservedAtUtc)
            .Set("countsTowardThreshold", CountsTowardThreshold)
            .Set("classification", Classification);
        node.Set("sampleSha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(node)));
        return node;
    }

    internal static CohortRegistrySample Read(JsonElement node, string label)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} carries a sample that is not an object.");
        }
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "subjectKey",
            "sampleKey",
            "repositoryId",
            "pullRequestId",
            "iterationId",
            "sourceCommit",
            "targetRefName",
            "runRoot",
            "manifestContractVersion",
            "manifestSha256",
            "toolkitHead",
            "cohortId",
            "entryId",
            "authorizationKind",
            "authorizedBy",
            "terminalState",
            "terminalOutcome",
            "realModelStarts",
            "realVerifierAssignments",
            "providerWrites",
            "writeToolInvocations",
            "wallClockSeconds",
            "censusComplete",
            "budgetCompliant",
            "auditSha256",
            "observedAtUtc",
            "countsTowardThreshold",
            "classification",
            "sampleSha256");

        var sample = new CohortRegistrySample
        {
            SubjectKey = StrictJson.RequireHex(node, "subjectKey", label, 64),
            SampleKey = StrictJson.RequireHex(node, "sampleKey", label, 64),
            RepositoryId = StrictJson.RequireString(node, "repositoryId", label),
            PullRequestId = StrictJson.RequireInt(node, "pullRequestId", label, 1, int.MaxValue),
            IterationId = StrictJson.RequireInt(node, "iterationId", label, 0, int.MaxValue),
            SourceCommit = StrictJson.RequireString(node, "sourceCommit", label),
            TargetRefName = StrictJson.RequireString(node, "targetRefName", label),
            RunRoot = StrictJson.RequireString(node, "runRoot", label),
            ManifestContractVersion = StrictJson.RequireString(node, "manifestContractVersion", label),
            ManifestSha256 = StrictJson.RequireString(node, "manifestSha256", label),
            ToolkitHead = StrictJson.RequireString(node, "toolkitHead", label),
            CohortId = StrictJson.RequireString(node, "cohortId", label),
            EntryId = StrictJson.RequireString(node, "entryId", label),
            AuthorizationKind = StrictJson.RequireString(node, "authorizationKind", label),
            AuthorizedBy = StrictJson.RequireString(node, "authorizedBy", label),
            TerminalState = StrictJson.RequireString(node, "terminalState", label),
            TerminalOutcome = StrictJson.RequireString(node, "terminalOutcome", label),
            RealModelStarts = StrictJson.RequireInt(node, "realModelStarts", label, 0, int.MaxValue),
            RealVerifierAssignments = StrictJson.RequireInt(node, "realVerifierAssignments", label, 0, int.MaxValue),
            ProviderWrites = StrictJson.RequireInt(node, "providerWrites", label, 0, int.MaxValue),
            WriteToolInvocations = StrictJson.RequireInt(node, "writeToolInvocations", label, 0, int.MaxValue),
            WallClockSeconds = StrictJson.RequireInt(node, "wallClockSeconds", label, 0, int.MaxValue),
            CensusComplete = StrictJson.RequireBool(node, "censusComplete", label),
            BudgetCompliant = StrictJson.RequireBool(node, "budgetCompliant", label),
            AuditSha256 = StrictJson.RequireString(node, "auditSha256", label),
            ObservedAtUtc = StrictJson.RequireString(node, "observedAtUtc", label),
            CountsTowardThreshold = StrictJson.RequireBool(node, "countsTowardThreshold", label),
            Classification = StrictJson.RequireString(node, "classification", label)
        };

        // The per-sample digest is re-derived rather than trusted. A registry is
        // read by more than the runner that wrote it, and a row that was edited in
        // place would otherwise arrive as an ordinary row.
        var recorded = StrictJson.RequireHex(node, "sampleSha256", label, 64);
        var described = sample.Describe();
        var derived = described.GetText("sampleSha256") ?? string.Empty;
        if (!string.Equals(recorded, derived, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} carries a sample digesting to {derived} and records {recorded}. A sample that no longer digests to what it " +
                "records is a sample somebody edited, and this build does not read one.");
        }
        if (sample.CountsTowardThreshold
            && !string.Equals(sample.Classification, CohortRegistryClassifications.Counted, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} carries a sample that counts toward the threshold while classified '{sample.Classification}'. " +
                "Only a sample this build classified as counted may count.");
        }
        return sample;
    }
}

/// <summary>
/// The two weights a defect can carry. They are not the same fact and must not be
/// read as one: a root this build could not read hides whatever it ran, while a root
/// it read and refused to count is fully known and merely does not qualify. Only the
/// first leaves a question open.
/// </summary>
internal static class CohortRegistryDefectKinds
{
    /// <summary>Evidence nobody could read. Whatever it holds is unknown to the account.</summary>
    internal const string Unreadable = "unreadable";

    /// <summary>Read in full, recorded so an operator sees it, and known not to qualify.</summary>
    internal const string Noted = "noted";

    internal const string Known = "'unreadable' and 'noted'";

    internal static bool IsKnown(string kind) => kind is Unreadable or Noted;
}

/// <summary>The words this build classifies a sample under, and the one that counts.</summary>
internal static class CohortRegistryClassifications
{    /// <summary>The only classification a counting sample may carry.</summary>
    internal const string Counted = "counted";

    /// <summary>A run over a subject the registry already holds. History, never a count.</summary>
    internal const string DiagnosticRepeat = "diagnosticRepeat";

    /// <summary>The cohort ran under a manifest contract whose budget unit this build refuses to rescore.</summary>
    internal const string UnsafeBudgetContract = "unsafeBudgetContract";

    /// <summary>The cohort was declared in a mode that cannot count, whatever the run did.</summary>
    internal const string DiagnosticMode = "diagnosticMode";

    /// <summary>No operator alias or no preview-only authorization is recorded against the run.</summary>
    internal const string AuthorizationMissing = "authorizationMissing";

    /// <summary>The entry did not reach the terminal the cohort declared as its target.</summary>
    internal const string TargetNotReached = "targetNotReached";

    /// <summary>The run's own census charged a remainder, so what it spent is not known exactly.</summary>
    internal const string CensusIncomplete = "censusIncomplete";

    /// <summary>Actual consumption stood above a declared ceiling in the unit this build spends.</summary>
    internal const string BudgetExceeded = "budgetExceeded";

    /// <summary>The run's audit records a write, so it was not the preview-only run it was authorized as.</summary>
    internal const string ProviderWriteObserved = "providerWriteObserved";

    /// <summary>
    /// The entry ended, and its own published evidence could not be read as this
    /// build's. What it did is unknown; that it looked is not.
    /// </summary>
    /// <remarks>
    /// The row exists to hold the subject. An entry whose evidence is refused really
    /// started its preparation - the refusal happens after the child has run - so a
    /// subject with no row at all would be offered again as though nothing had ever
    /// been pointed at it. Holding it costs an honest under-count; not holding it
    /// buys a dishonest one.
    /// </remarks>
    internal const string EvidenceUnreadable = "evidenceUnreadable";

    /// <summary>
    /// Whether a row is evidence that this pull request was already put in front of
    /// the models, whatever else it failed to be.
    /// </summary>
    /// <remarks>
    /// Not the same question as 'may it count'. A run that finished under a contract
    /// this build refuses to score, or one whose evidence could not be read, did not
    /// qualify - but it did look, and a second look at work the toolkit has already
    /// seen is not a second independent observation.
    ///
    /// Refused-contract rows are read from a manifest alone, so their model-start
    /// counter is a zero this build declined to read rather than a measurement: the
    /// classification, not the counter, is what says they observed.
    ///
    /// A row the operator declared as history - a repeat, or a cohort declared in a
    /// mode that cannot count - is deliberately excluded. Those are runs whose whole
    /// purpose was to not disturb the account, and letting one evict the row it was
    /// declared alongside would make a diagnostic run destructive.
    /// </remarks>
    internal static bool IsPriorObservation(string classification, long realModelStarts) =>
        !string.Equals(classification, DiagnosticRepeat, StringComparison.Ordinal)
        && !string.Equals(classification, DiagnosticMode, StringComparison.Ordinal)
        && (realModelStarts > 0
            || string.Equals(classification, UnsafeBudgetContract, StringComparison.Ordinal)
            || string.Equals(classification, EvidenceUnreadable, StringComparison.Ordinal)
            // A started preparation that did not reach the target may have faulted
            // before its own supervisor established full child custody. It still
            // observed the subject, and holding that subject after the runner's
            // live reservation closes prevents a second cohort from spending it
            // while an unconfirmed descendant may remain.
            || string.Equals(classification, TargetNotReached, StringComparison.Ordinal));

    private static readonly string[] All =
    [
        Counted,
        DiagnosticRepeat,
        UnsafeBudgetContract,
        DiagnosticMode,
        AuthorizationMissing,
        TargetNotReached,
        CensusIncomplete,
        BudgetExceeded,
        ProviderWriteObserved,
        EvidenceUnreadable
    ];

    internal static bool IsKnown(string classification) => Array.IndexOf(All, classification) >= 0;
}

/// <summary>How a cohort's samples may be recorded against the registry.</summary>
internal static class CohortRegistryModes
{
    /// <summary>The default. One sample per subject, and a subject already held is refused before any child.</summary>
    internal const string Count = "count";

    /// <summary>
    /// A deliberate repeat. Every sample it records is history, and no sample it
    /// records can ever count - which is what makes it safe to run a subject the
    /// registry already holds.
    /// </summary>
    internal const string Diagnostic = "diagnostic";

    internal static bool IsKnown(string mode) =>
        string.Equals(mode, Count, StringComparison.Ordinal) || string.Equals(mode, Diagnostic, StringComparison.Ordinal);
}

/// <summary>
/// The manifest's binding to a registry: which file, which revision of it, which
/// subject this cohort intends to spend, and whether it may count.
/// </summary>
internal sealed record CohortRegistryBinding
{
    /// <summary>The digest a manifest declares when it is starting the account rather than adding to one.</summary>
    internal const string UnstartedRegistry = "none";

    internal required string Path { get; init; }

    /// <summary>The registry revision the operator declared this cohort against.</summary>
    internal required string Sha256 { get; init; }

    /// <summary>The subject key the cohort intends to occupy, restated so a manifest cannot silently point elsewhere.</summary>
    internal required string TargetSubjectKey { get; init; }

    internal required string Mode { get; init; }

    internal bool CountsTowardThreshold =>
        string.Equals(Mode, CohortRegistryModes.Count, StringComparison.Ordinal);

    internal static CohortRegistryBinding Read(JsonElement node, string label)
    {
        StrictJson.RequireNoUnknownFields(node, label, "path", "sha256", "targetSubjectKey", "mode");
        var mode = StrictJson.RequireString(node, "mode", label);
        if (!CohortRegistryModes.IsKnown(mode))
        {
            throw new ContractException(
                $"The {label} declares registry mode '{mode}'. This build records a cohort as '{CohortRegistryModes.Count}', which " +
                $"occupies a subject, or as '{CohortRegistryModes.Diagnostic}', which may repeat one and can never count.");
        }
        // 'none' is the one non-digest this field accepts, and it means exactly one
        // thing: the operator is starting the account with this cohort. It is
        // checked against an empty registry rather than treated as a wildcard, so
        // it cannot be used to run against a registry that already holds subjects.
        var sha256 = StrictJson.RequireString(node, "sha256", label);
        if (!string.Equals(sha256, UnstartedRegistry, StringComparison.Ordinal)
            && (sha256.Length != 64 || !StrictJson.IsLowerHex(sha256)))
        {
            throw new ContractException(
                $"The {label} field 'sha256' is neither 64 lower-case hexadecimal characters nor '{UnstartedRegistry}', which is how a " +
                "manifest declares that it is starting the account rather than adding to one.");
        }
        return new CohortRegistryBinding
        {
            Path = CohortManifest.RequireRootedPath(StrictJson.RequireString(node, "path", label), "registry path", label),
            Sha256 = sha256,
            TargetSubjectKey = StrictJson.RequireHex(node, "targetSubjectKey", label, 64),
            Mode = mode
        };
    }

    internal MapNode Describe() => new MapNode()
        .Set("path", Path)
        .Set("sha256", Sha256)
        .Set("targetSubjectKey", TargetSubjectKey)
        .Set("mode", Mode);
}

/// <summary>
/// A signed inventory of the subjects this toolkit has been run over.
/// </summary>
internal sealed class CohortRegistry
{
    internal const string ContractVersionValue = "devpilot.shadow-cohort.registry.v1";
    internal const string KindValue = "shadow-cohort-registry";
    private const string Label = "shadow cohort registry";

    private readonly List<CohortRegistrySample> _samples;
    private readonly List<(string Kind, string Source, string Reason)> _defects;

    private CohortRegistry(
        string path,
        string registryId,
        int revision,
        string registrySha256,
        List<CohortRegistrySample> samples,
        List<(string Kind, string Source, string Reason)> defects)
    {
        Path = path;
        RegistryId = registryId;
        Revision = revision;
        RegistrySha256 = registrySha256;
        PreviousRegistrySha256 = "none";
        _samples = samples;
        _defects = defects;
    }

    internal string Path { get; }

    internal string RegistryId { get; }

    internal int Revision { get; private set; }

    /// <summary>The digest of the revision on disk, which is what a manifest binds.</summary>
    internal string RegistrySha256 { get; private set; }

    /// <summary>
    /// The digest this revision says it succeeded, which is what lets a resume
    /// recognise a write its own predecessor made and did not live to commit.
    /// </summary>
    internal string PreviousRegistrySha256 { get; private set; }

    internal IReadOnlyList<CohortRegistrySample> Samples => _samples;

    internal IReadOnlyList<(string Kind, string Source, string Reason)> Defects => _defects;

    /// <summary>
    /// The number of roots the account could not read, which is the number of open
    /// questions standing between it and a provable answer.
    /// </summary>
    internal int UnreadableDefectCount =>
        _defects.Count(defect => string.Equals(defect.Kind, CohortRegistryDefectKinds.Unreadable, StringComparison.Ordinal));

    /// <summary>
    /// The digest of the evidence alone, comparable across rebuilds and machines.
    /// </summary>
    internal string EvidenceSha256 => EvidenceDigestOf(_samples, _defects);

    internal static string KeyPathFor(string registryPath) => registryPath + ".key";

    /// <summary>
    /// The handle a registry carries for its own life, derived from where it lives.
    /// </summary>
    /// <remarks>
    /// Derived rather than declared, so a registry the operator has not started yet
    /// has the same handle as the one the first revision will carry, and so nothing
    /// about a subject can reach it. It is a digest of the path and nothing else.
    /// </remarks>
    internal static string DerivedRegistryId(string registryPath) =>
        CanonicalJson.Sha256HexOfText(System.IO.Path.GetFullPath(registryPath).ToLowerInvariant())[..32];

    /// <summary>
    /// The identity of one distinct subject: a repository and a pull request number.
    /// </summary>
    /// <remarks>
    /// Folded to lower case before it is digested, because a repository identity
    /// that differs only in case is the same repository, and a key that told them
    /// apart would let the same pull request be spent twice by retyping it. The
    /// number is rendered invariantly for the same reason.
    /// </remarks>
    internal static string SubjectKeyOf(string repositoryId, int pullRequestId)
    {
        var folded = repositoryId.Trim().ToLowerInvariant() + "#" + pullRequestId.ToString(CultureInfo.InvariantCulture);
        return CanonicalJson.Sha256HexOfText(folded);
    }

    internal static string RepositoryIdOf(CohortEntry entry) =>
        entry.Organization + "/" + entry.Project + "/" + entry.Repository;

    internal static string SubjectKeyOf(CohortEntry entry) =>
        SubjectKeyOf(RepositoryIdOf(entry), entry.PullRequestId);

    /// <summary>
    /// A sample's own identity: the subject it was taken over, plus the run that
    /// took it. Two runs over one subject are two samples; one run re-read is one.
    /// </summary>
    internal static string SampleKeyOf(string subjectKey, string cohortId, string entryId, string auditSha256) =>
        CanonicalJson.Sha256HexOfText(subjectKey + "|" + cohortId + "|" + entryId + "|" + auditSha256);

    internal static byte[] LoadOrMintKey(string registryPath, out bool preexisted)
    {
        var keyPath = KeyPathFor(registryPath);
        if (File.Exists(keyPath))
        {
            preexisted = true;
            return CoordinatorState.ReadSigningKey(keyPath, "cohort registry key");
        }
        preexisted = false;
        return RandomNumberGenerator.GetBytes(CoordinatorState.SigningKeyLength);
    }

    /// <summary>
    /// Reads and authenticates a registry, or opens an empty one when the operator
    /// has not started one yet.
    /// </summary>
    /// <remarks>
    /// A key with no registry beside it is the one shape that is never fresh. The key
    /// is written just before the first revision, so a key alone means either that a
    /// registry which existed has since been removed, or that the very first write was
    /// interrupted between the two. Neither is a state to open an empty account over:
    /// in the first case every subject it held would be free to spend again, and in
    /// the second the rebuild is what signs the file with the key already there. So it
    /// refuses and sends the operator to the rebuild, which reads the run roots.
    /// </remarks>
    internal static CohortRegistry LoadOrFresh(string registryPath, byte[] key, bool keyPreexisted)
    {
        var full = System.IO.Path.GetFullPath(registryPath);
        if (!File.Exists(full))
        {
            if (keyPreexisted)
            {
                throw new ContractException(
                    $"The cohort registry at '{full}' is missing and its signing key is not. Either it was removed - and the subjects it " +
                    "accounted for cannot be counted from anywhere else, so a registry that started over would let every one of them be " +
                    "spent again - or its first write was interrupted. Rebuild it from the run roots with --rebuild-registry rather than " +
                    "letting this run open an empty one.");
            }
            return new CohortRegistry(full, DerivedRegistryId(full), 0, "none", [], []);
        }
        return Load(full, key);
    }

    internal static CohortRegistry Load(string registryPath, byte[] key)
    {
        var full = System.IO.Path.GetFullPath(registryPath);
        var bytes = StrictJson.ReadFileBytes(full, Label);
        var root = StrictJson.ReadObjectBytes(bytes, full, Label);
        StrictJson.RequireNoUnknownFields(
            root,
            Label,
            "contractVersion",
            "kind",
            "registryId",
            "revision",
            "previousRegistrySha256",
            "updatedAtUtc",
            "evidenceSha256",
            "inventory",
            "samples",
            "defects",
            "registrySha256",
            "signature");

        StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, Label);
        StrictJson.RequireLiteral(root, "kind", KindValue, Label);
        var registryId = StrictJson.RequireString(root, "registryId", Label);
        CohortManifest.RequireOpaqueShape(registryId, Label, "registryId", 8, 64);
        var revision = StrictJson.RequireInt(root, "revision", Label, 1, int.MaxValue);

        var samples = new List<CohortRegistrySample>();
        var index = 0;
        foreach (var node in StrictJson.RequireArray(root, "samples", Label))
        {
            samples.Add(CohortRegistrySample.Read(
                node,
                $"{Label} samples[{index.ToString(CultureInfo.InvariantCulture)}]"));
            index++;
        }

        var defects = new List<(string Kind, string Source, string Reason)>();
        foreach (var node in StrictJson.RequireArray(root, "defects", Label))
        {
            if (node.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {Label} carries a defect that is not an object.");
            }
            StrictJson.RequireNoUnknownFields(node, Label + " defect", "kind", "source", "reason");
            var kind = StrictJson.RequireString(node, "kind", Label + " defect");
            if (!CohortRegistryDefectKinds.IsKnown(kind))
            {
                throw new ContractException(
                    $"The {Label} carries a defect of kind '{kind}', and this build knows " +
                    $"{CohortRegistryDefectKinds.Known}. A defect whose kind is not read is a defect whose weight is not known.");
            }
            defects.Add((
                kind,
                StrictJson.RequireString(node, "source", Label + " defect"),
                StrictJson.RequireString(node, "reason", Label + " defect")));
        }

        RequireOneCountingSamplePerSubject(samples);

        var recordedSelf = StrictJson.RequireHex(root, "registrySha256", Label, 64);
        var recordedSignature = StrictJson.RequireObject(root, "signature", Label);
        StrictJson.RequireNoUnknownFields(recordedSignature, Label + " signature", "algorithm", "value");
        StrictJson.RequireLiteral(recordedSignature, "algorithm", "HMACSHA256", Label + " signature");
        var signatureValue = StrictJson.RequireHex(recordedSignature, "value", Label + " signature", 64);

        var previous = StrictJson.RequireString(root, "previousRegistrySha256", Label);
        var updatedAt = StrictJson.RequireString(root, "updatedAtUtc", Label);
        var rebuilt = Compose(registryId, revision, previous, updatedAt, samples, defects);
        // The inventory is derived from the rows, so composing it fresh would let an
        // edited inventory ride along under a digest that never covered it. What the
        // file claims about itself is read and held to what the rows say. The
        // evidence digest is derived the same way and held the same way, because it
        // is the value two machines compare their accounts on: recomposing it would
        // make it the one field in the envelope nobody's signature covers.
        RequireInventoryMatches(root, samples, defects, full);
        var statedEvidence = StrictJson.RequireHex(root, "evidenceSha256", Label, 64);
        var derivedEvidence = EvidenceDigestOf(samples, defects);
        if (!string.Equals(statedEvidence, derivedEvidence, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {Label} at '{full}' states an evidence digest of {statedEvidence} while its rows and defects digest to " +
                $"{derivedEvidence}. An account whose evidence digest disagrees with its own evidence is an account somebody edited.");
        }
        var derivedSelf = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(rebuilt));
        if (!string.Equals(recordedSelf, derivedSelf, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {Label} at '{full}' digests to {derivedSelf} and records {recordedSelf}. A registry that no longer digests to what " +
                "it records is a registry somebody edited.");
        }
        rebuilt.Set("registrySha256", derivedSelf);
        var derivedSignature = CanonicalJson.HmacHex(key, CanonicalJson.Canonical(rebuilt));
        if (!CryptographicOperations.FixedTimeEquals(
                Encoding.ASCII.GetBytes(derivedSignature),
                Encoding.ASCII.GetBytes(signatureValue)))
        {
            throw new ContractException(
                $"The {Label} at '{full}' does not authenticate against the key beside it. A registry whose signature does not verify " +
                "is not evidence of anything, and this build does not count from one.");
        }

        return new CohortRegistry(full, registryId, revision, derivedSelf, samples, defects)
        {
            PreviousRegistrySha256 = previous
        };
    }

    /// <summary>
    /// Holds the inventory the file states to the inventory its own rows imply.
    /// </summary>
    /// <remarks>
    /// The inventory is derived, so a reader that recomputed it would authenticate a
    /// document whose headline numbers nobody ever signed. An operator reads those
    /// numbers; they are held to the rows.
    /// </remarks>
    private static void RequireInventoryMatches(
        JsonElement root,
        IReadOnlyList<CohortRegistrySample> samples,
        IReadOnlyList<(string Kind, string Source, string Reason)> defects,
        string path)
    {
        var stated = StrictJson.RequireObject(root, "inventory", Label);
        StrictJson.RequireNoUnknownFields(
            stated,
            Label + " inventory",
            "sampleCount",
            "countingSampleCount",
            "distinctSubjectCount",
            "defectCount",
            "unreadableDefectCount");
        var derived = new (string Field, int Expected)[]
        {
            ("sampleCount", samples.Count),
            ("countingSampleCount", samples.Count(sample => sample.CountsTowardThreshold)),
            ("distinctSubjectCount", samples.Select(sample => sample.SubjectKey).Distinct(StringComparer.Ordinal).Count()),
            ("defectCount", defects.Count),
            ("unreadableDefectCount", defects.Count(defect => defect.Kind == CohortRegistryDefectKinds.Unreadable)),
        };
        foreach (var (field, expected) in derived)
        {
            var actual = StrictJson.RequireInt(stated, field, Label + " inventory", 0, int.MaxValue);
            if (actual != expected)
            {
                throw new ContractException(
                    $"The {Label} at '{path}' states an inventory of {actual.ToString(CultureInfo.InvariantCulture)} for '{field}' " +
                    $"while its rows carry {expected.ToString(CultureInfo.InvariantCulture)}. An account whose summary disagrees with " +
                    "its own evidence is an account somebody edited.");
            }
        }
    }

    /// <summary>
    /// The invariant the whole account rests on: a subject is spent once.
    /// </summary>
    private static void RequireOneCountingSamplePerSubject(IReadOnlyList<CohortRegistrySample> samples)
    {
        var counting = new HashSet<string>(StringComparer.Ordinal);
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var sample in samples)
        {
            if (!keys.Add(sample.SampleKey))
            {
                throw new ContractException(
                    $"The {Label} records sample {sample.SampleKey} twice. One run over one subject has one row.");
            }
            if (!sample.CountsTowardThreshold)
            {
                continue;
            }
            if (!counting.Add(sample.SubjectKey))
            {
                throw new ContractException(
                    $"The {Label} counts subject {sample.SubjectKey} more than once. A distinct pull request is spent once, and a " +
                    "registry that counted one twice would report a reach this toolkit never had.");
            }
        }
    }

    internal CohortRegistrySample? CountingSampleFor(string subjectKey) =>
        _samples.FirstOrDefault(sample =>
            sample.CountsTowardThreshold && string.Equals(sample.SubjectKey, subjectKey, StringComparison.Ordinal));

    internal bool HoldsSubject(string subjectKey) =>
        _samples.Any(sample => string.Equals(sample.SubjectKey, subjectKey, StringComparison.Ordinal));

    internal CohortRegistrySample? SampleFor(string sampleKey) =>
        _samples.FirstOrDefault(sample => string.Equals(sample.SampleKey, sampleKey, StringComparison.Ordinal));

    /// <summary>The first sample held for a subject, counted or not, in registry order.</summary>
    internal CohortRegistrySample? AnySampleFor(string subjectKey) =>
        _samples.FirstOrDefault(sample => string.Equals(sample.SubjectKey, subjectKey, StringComparison.Ordinal));

    /// <summary>
    /// True when some OTHER run has already put this subject on record.
    /// </summary>
    /// <remarks>
    /// The distinction a resume depends on. A cohort that recorded its own sample
    /// and was then killed finds its subject held on the way back in; treating that
    /// as a duplicate would make every resume refuse the work it had already done.
    ///
    /// 'Its own' is settled by the manifest digest, not by the cohort id. The id is
    /// a string an operator types, and a manifest copied from a finished one keeps
    /// it: that copy would find the subject it is about to spend a second time and
    /// read it as its own earlier attempt. The journal already refuses a manifest
    /// edited between runs, so a genuine resume presents byte-identical bytes and
    /// the same digest, while a copy - a new journal root, a new output root, a
    /// re-pointed registry revision - cannot.
    /// </remarks>
    internal bool HoldsSubjectFromAnotherRun(string subjectKey, string manifestSha256) =>
        _samples.Any(sample =>
            string.Equals(sample.SubjectKey, subjectKey, StringComparison.Ordinal)
            && !string.Equals(sample.ManifestSha256, manifestSha256, StringComparison.Ordinal));

    /// <summary>The sample this run itself already recorded for a subject, if any.</summary>
    internal CohortRegistrySample? OwnSampleFor(string subjectKey, string manifestSha256) =>
        _samples.FirstOrDefault(sample =>
            string.Equals(sample.SubjectKey, subjectKey, StringComparison.Ordinal)
            && string.Equals(sample.ManifestSha256, manifestSha256, StringComparison.Ordinal));

    internal int CountingSampleCount => _samples.Count(sample => sample.CountsTowardThreshold);

    internal int DistinctSubjectCount =>
        _samples.Select(sample => sample.SubjectKey).Distinct(StringComparer.Ordinal).Count();

    /// <summary>
    /// Records one sample, replacing a re-read of the same run rather than adding a
    /// second row for it, and republishes the file atomically under its key.
    /// </summary>
    /// <remarks>
    /// Idempotent by sample key, because the runner that calls this can be killed
    /// between writing the registry and committing the digest it wrote, and the
    /// resume that follows re-reads the same entry's evidence and arrives here with
    /// the same sample. A second row would turn one run into two, and two rows for
    /// one run is the same defect as two runs for one subject.
    /// </remarks>
    internal void Record(byte[] key, CohortRegistrySample sample)
    {
        var existingIndex = _samples.FindIndex(candidate =>
            string.Equals(candidate.SampleKey, sample.SampleKey, StringComparison.Ordinal));
        // Validated against a copy before anything is mutated, so a refused record
        // leaves the account exactly as it found it rather than in memory holding a
        // row it could not write.
        var proposed = new List<CohortRegistrySample>(_samples);
        if (existingIndex >= 0)
        {
            proposed[existingIndex] = sample;
        }
        else
        {
            proposed.Add(sample);
        }
        // A row about an entry that ENDED supersedes the placeholder the same run left
        // while it was still open. The two carry different sample keys - a placeholder
        // is keyed on what was knowable before there was an audit - so idempotence by
        // key alone would leave both, and the account would show one run twice: once as
        // an open question and once as the answer. The replacement is bound to the same
        // run in full, manifest digest included, so it can only ever consume this run's
        // own earlier ignorance.
        if (!CohortRegistryAdmission.IsPlaceholder(sample))
        {
            proposed.RemoveAll(candidate =>
                !string.Equals(candidate.SampleKey, sample.SampleKey, StringComparison.Ordinal)
                && CohortRegistryAdmission.IsPlaceholder(candidate)
                && string.Equals(candidate.SubjectKey, sample.SubjectKey, StringComparison.Ordinal)
                && string.Equals(candidate.CohortId, sample.CohortId, StringComparison.Ordinal)
                && string.Equals(candidate.EntryId, sample.EntryId, StringComparison.Ordinal)
                && string.Equals(candidate.ManifestSha256, sample.ManifestSha256, StringComparison.Ordinal));
        }
        RequireOneCountingSamplePerSubject(proposed);
        _samples.Clear();
        _samples.AddRange(proposed);
        Write(key, Revision + 1);
    }

    /// <summary>
    /// Refuses to replace a revision that is no longer the one this instance read.
    /// </summary>
    /// <remarks>
    /// The account is shared - that is the whole point of it - and nothing outside
    /// it serializes two cohorts writing to it. Two runners that both loaded
    /// revision 5 and both composed a revision 6 would each publish a file holding
    /// their own row and not the other's, and the subject the loser recorded would
    /// be free to spend again. So the bytes on disk are re-read and re-digested
    /// immediately before the replacement, and a file that moved is refused rather
    /// than overwritten. The lock below narrows the window; this check is what
    /// closes it, because it does not depend on the lock being honoured.
    /// </remarks>
    private void RequireStillAtLoadedRevision()
    {
        if (!File.Exists(Path))
        {
            if (!string.Equals(RegistrySha256, "none", StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"The {Label} at '{Path}' digested to {RegistrySha256} when this run read it and is no longer there. A registry that " +
                    "vanished under a run is not one this build writes over.");
            }
            return;
        }
        if (string.Equals(RegistrySha256, "none", StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {Label} at '{Path}' was not there when this run opened the account and is there now. Another writer started it, and " +
                "publishing over them would drop whatever they recorded.");
        }
        var bytes = StrictJson.ReadFileBytes(Path, Label);
        var root = StrictJson.ReadObjectBytes(bytes, Path, Label);
        if (!root.TryGetProperty("registrySha256", out var declared)
            || declared.ValueKind != JsonValueKind.String
            || !string.Equals(declared.GetString(), RegistrySha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {Label} at '{Path}' is no longer the revision this run read ({RegistrySha256}). Another cohort wrote to the account " +
                "while this one was running, and replacing it now would drop the subject they recorded. Re-run against the current revision.");
        }
    }

    private void Write(byte[] key, int revision)
    {
        var parent = System.IO.Path.GetDirectoryName(Path);
        if (!string.IsNullOrEmpty(parent))
        {
            Directory.CreateDirectory(parent);
        }
        // Held across the read-modify-write so two runners on one machine take turns
        // rather than race. It is an optimisation on the check inside, not a
        // substitute for it: a lock nobody else takes protects nothing.
        using var gate = AcquireWriteGate();
        RequireStillAtLoadedRevision();
        // Under the gate, the key on disk wins. Two runs that both open an account
        // nobody has started yet each mint their own key; if one persists its key and
        // then stops, the other would otherwise sign the first revision with a key no
        // reader will ever load - producing a registry that authenticates against
        // nothing and cannot be opened again, only rebuilt. Adopting the persisted key
        // here is not a weakening: it is the same key the reader will use, read through
        // the same strict reader, and a key that is not there is still minted fresh.
        key = AdoptPersistedKey(key);
        Sort(_samples);
        SortDefects(_defects);
        var body = Compose(
            RegistryId,
            revision,
            RegistrySha256,
            DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
            _samples,
            _defects);
        var self = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(body));
        body.Set("registrySha256", self);
        body.Set("signature", new MapNode()
            .Set("algorithm", "HMACSHA256")
            .Set("value", CanonicalJson.HmacHex(key, CanonicalJson.Canonical(body))));
        // The key is written before the revision it signs, so an interrupted first
        // write leaves a key with no registry - a state the reader refuses with an
        // actionable message and a rebuild recovers from, signing the rebuilt file
        // with the key already there. The other order leaves a signed registry with
        // no key, which nothing can authenticate and nothing can rebuild over: the
        // only way out would be deleting the evidence.
        var previous = RegistrySha256;
        WriteKeyIfAbsent(key);
        CanonicalJson.WriteFileAtomic(Path, CanonicalJson.Readable(body));
        PreviousRegistrySha256 = previous;
        RegistrySha256 = self;
        Revision = revision;
    }

    /// <summary>
    /// A machine-wide gate over the account file, held for the read-modify-write.
    /// </summary>
    private FileStream AcquireWriteGate()
    {
        var gatePath = Path + ".lock";
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (true)
        {
            try
            {
                return new FileStream(gatePath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException) when (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(100);
            }
            catch (IOException)
            {
                throw new ContractException(
                    $"The {Label} at '{Path}' is held by another writer and did not come free. A registry two runs write at once is a " +
                    "registry that loses one of them, so this run stops rather than guessing.");
            }
        }
    }

    /// <summary>
    /// The key this revision will be signed with: the one already on disk if there is
    /// one, otherwise the one this run minted.
    /// </summary>
    private byte[] AdoptPersistedKey(byte[] key)
    {
        var keyPath = KeyPathFor(Path);
        return File.Exists(keyPath)
            ? CoordinatorState.ReadSigningKey(keyPath, "cohort registry key")
            : key;
    }

    private void WriteKeyIfAbsent(byte[] key)
    {
        var keyPath = KeyPathFor(Path);
        if (File.Exists(keyPath))
        {
            return;
        }
        try
        {
            using var stream = new FileStream(keyPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(key, 0, key.Length);
            // Flushed through to the device before the revision it signs is published,
            // so a power loss cannot leave a signed registry whose key never reached
            // the disk.
            stream.Flush(true);
        }
        catch (IOException) when (File.Exists(keyPath))
        {
            // Another writer minted it first. Whether this run's signature verifies
            // against it is decided by the reader, not papered over here.
        }
    }

    /// <summary>
    /// Deterministic order, so two rebuilds over the same roots produce the same
    /// bytes and the same digest.
    /// </summary>
    private static void Sort(List<CohortRegistrySample> samples) =>
        samples.Sort((left, right) =>
        {
            var bySubject = string.CompareOrdinal(left.SubjectKey, right.SubjectKey);
            return bySubject != 0 ? bySubject : string.CompareOrdinal(left.SampleKey, right.SampleKey);
        });

    /// <summary>
    /// The same for the defects, which otherwise keep the order the caller happened
    /// to name their roots in and would move the digest without changing what is known.
    /// </summary>
    private static void SortDefects(List<(string Kind, string Source, string Reason)> defects) =>
        defects.Sort((left, right) =>
        {
            var bySource = string.CompareOrdinal(left.Source, right.Source);
            if (bySource != 0)
            {
                return bySource;
            }
            var byReason = string.CompareOrdinal(left.Reason, right.Reason);
            return byReason != 0 ? byReason : string.CompareOrdinal(left.Kind, right.Kind);
        });

    private static string EvidenceDigestOf(
        IReadOnlyList<CohortRegistrySample> samples,
        IReadOnlyList<(string Kind, string Source, string Reason)> defects)
    {
        var sampleNodes = new ListNode();
        foreach (var sample in samples)
        {
            sampleNodes.Add(sample.Describe());
        }
        var defectNodes = new ListNode();
        foreach (var (kind, source, reason) in defects)
        {
            defectNodes.Add(new MapNode().Set("kind", kind).Set("source", source).Set("reason", reason));
        }
        return CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(new MapNode()
            .Set("contractVersion", ContractVersionValue)
            .Set("samples", sampleNodes)
            .Set("defects", defectNodes)));
    }

    private static MapNode Compose(
        string registryId,
        int revision,
        string previousRegistrySha256,
        string updatedAtUtc,
        IReadOnlyList<CohortRegistrySample> samples,
        IReadOnlyList<(string Kind, string Source, string Reason)> defects)
    {
        var sampleNodes = new ListNode();
        foreach (var sample in samples)
        {
            sampleNodes.Add(sample.Describe());
        }
        var defectNodes = new ListNode();
        foreach (var (kind, source, reason) in defects)
        {
            defectNodes.Add(new MapNode().Set("kind", kind).Set("source", source).Set("reason", reason));
        }
        // The digest an operator can compare across machines and across rebuilds.
        // It covers the evidence and nothing else: not the revision the destination
        // happened to be at, not the moment of publication, not the path the file
        // was written to. Two rebuilds over the same roots agree here even when the
        // envelope around them cannot.
        var evidence = EvidenceDigestOf(samples, defects);
        return new MapNode()
            .Set("contractVersion", ContractVersionValue)
            .Set("kind", KindValue)
            .Set("registryId", registryId)
            .Set("revision", revision)
            .Set("previousRegistrySha256", previousRegistrySha256)
            .Set("updatedAtUtc", updatedAtUtc)
            .Set("evidenceSha256", evidence)
            .Set("inventory", new MapNode()
                .Set("sampleCount", samples.Count)
                .Set("countingSampleCount", samples.Count(sample => sample.CountsTowardThreshold))
                .Set("distinctSubjectCount", samples.Select(sample => sample.SubjectKey).Distinct(StringComparer.Ordinal).Count())
                .Set("defectCount", defects.Count)
                .Set("unreadableDefectCount", defects.Count(defect => defect.Kind == CohortRegistryDefectKinds.Unreadable)))
            .Set("samples", sampleNodes)
            .Set("defects", defectNodes);
    }

    /// <summary>
    /// Publishes a registry composed elsewhere - the rebuild's product - under a
    /// fresh revision, at the path this instance names.
    /// </summary>
    internal void Publish(byte[] key) => Write(key, Revision + 1);

    internal static CohortRegistry ForRebuild(
        string registryPath,
        int revision,
        string previousSha256,
        List<CohortRegistrySample> samples,
        List<(string Kind, string Source, string Reason)> defects) =>
        new(
            System.IO.Path.GetFullPath(registryPath),
            DerivedRegistryId(registryPath),
            revision,
            previousSha256,
            samples,
            defects);
}

/// <summary>
/// Decides, from signed evidence alone, whether one finished entry may occupy its
/// subject.
/// </summary>
/// <remarks>
/// Every clause is a refusal to count, and the order they are asked in is the
/// order an operator would want them reported: the contract the run was declared
/// under, then the authorization it carried, then whether it arrived, then whether
/// what it spent is known exactly, then whether that was inside the ceilings, then
/// whether it wrote. The first clause that fails is the classification, so a
/// sample never carries a reason that is merely one of several.
/// </remarks>
internal static class CohortRegistryAdmission
{
    /// <summary>
    /// The two things a sample cannot carry about itself: whether the cohort that
    /// produced it was allowed to count at all, and which terminal it was aiming at.
    /// </summary>
    internal readonly record struct Criteria(string Mode, string TargetState);

    /// <summary>
    /// What earlier entries of the same cohort had already spent when this one ran.
    /// </summary>
    /// <remarks>
    /// The ceilings are the cohort's, not the entry's. An entry measured against the
    /// global ceiling on its own would let three entries costing five model starts
    /// each all count under a ceiling of ten, and the account would report three
    /// spent subjects for a cohort that overran. So what came before is carried in
    /// and the comparison is made on the running total.
    /// </remarks>
    internal readonly record struct Spent(long ModelStarts, long VerifierAssignments, long WallClockSeconds)
    {
        internal static Spent Nothing => new(0, 0, 0);
    }

    /// <summary>
    /// A row about an entry that has no ENDING, and is therefore a statement of
    /// ignorance rather than a closed fact about a spend.
    /// </summary>
    /// <remarks>
    /// The journal's outcome is 'none' while a launch is open, and 'unknown' when
    /// there was no journal to read at all. An entry that ended - completed, failed,
    /// or had its evidence refused - is never one, however unreadable its artifacts
    /// turned out to be. Only a placeholder may be superseded by a later reading of
    /// the same run, and only a placeholder may be retracted; that distinction is
    /// what keeps both escapes away from rows that record a real spend.
    /// </remarks>
    internal static bool IsPlaceholder(CohortRegistrySample sample) =>
        !sample.CountsTowardThreshold
        && string.Equals(
            sample.Classification,
            CohortRegistryClassifications.EvidenceUnreadable,
            StringComparison.Ordinal)
        && (string.Equals(sample.TerminalOutcome, "none", StringComparison.Ordinal)
            || string.Equals(sample.TerminalOutcome, "unknown", StringComparison.Ordinal));

    internal static (bool Counts, string Classification) Classify(
        Criteria criteria,
        CohortRegistrySample draft,
        bool subjectHeldElsewhere)
    {
        if (!string.Equals(criteria.Mode, CohortRegistryModes.Count, StringComparison.Ordinal))
        {
            // Asked before the write clause, and deliberately. A diagnostic run is
            // one this account must be able to treat as never having happened -
            // IsPriorObservation excludes it, so a later counting run over the same
            // subject is still allowed. Every other non-counting classification is
            // an OBSERVATION: it holds the subject. Were a diagnostic run that wrote
            // filed under providerWriteObserved it would start holding subjects, and
            // the exclusion the diagnostic mode exists to provide would silently
            // stop working. The write itself is not lost: the sample carries the
            // counts, they are covered by the digest, and the inventory surfaces
            // them regardless of how the row is classified.
            return (false, CohortRegistryClassifications.DiagnosticMode);
        }
        // Asked ahead of every remaining clause. Those are reasons a run does not
        // qualify; this one is a reason the run was not the run it was authorized to
        // be. A repeat that wrote, or a run over a refused contract that wrote, would
        // otherwise be filed under the milder fact and an operator reading the
        // account would never learn that the zero-write claim had been broken.
        if (draft.ProviderWrites > 0 || draft.WriteToolInvocations > 0)
        {
            return (false, CohortRegistryClassifications.ProviderWriteObserved);
        }
        if (subjectHeldElsewhere)
        {
            return (false, CohortRegistryClassifications.DiagnosticRepeat);
        }
        // A cohort declared under a contract this build refuses to load cannot
        // reach here through the runner at all; the clause exists for the rebuild,
        // which reads roots written by earlier builds and has to classify them
        // rather than load them.
        if (!string.Equals(draft.ManifestContractVersion, CohortManifest.ContractVersionValue, StringComparison.Ordinal))
        {
            return (false, CohortRegistryClassifications.UnsafeBudgetContract);
        }
        if (string.Equals(draft.AuthorizedBy, "none", StringComparison.Ordinal)
            || draft.AuthorizedBy.Length == 0
            || !string.Equals(draft.AuthorizationKind, CohortExecution.PreviewOnlyKind, StringComparison.Ordinal))
        {
            return (false, CohortRegistryClassifications.AuthorizationMissing);
        }
        if (!string.Equals(draft.TerminalOutcome, CohortEntryOutcomes.Complete, StringComparison.Ordinal)
            || !string.Equals(draft.TerminalState, criteria.TargetState, StringComparison.Ordinal))
        {
            return (false, CohortRegistryClassifications.TargetNotReached);
        }
        if (!draft.CensusComplete)
        {
            return (false, CohortRegistryClassifications.CensusIncomplete);
        }
        if (!draft.BudgetCompliant)
        {
            return (false, CohortRegistryClassifications.BudgetExceeded);
        }
        return (true, CohortRegistryClassifications.Counted);
    }

    /// <summary>Composes the sample one finished entry leaves behind, counted or not.</summary>
    /// <remarks>
    /// The observation time is supplied rather than taken from the clock, because
    /// it is covered by the sample digest. A sample records when the run it
    /// describes ENDED, not when someone happened to read it, so two rebuilds over
    /// the same immutable roots settle on the same rows and the same digests.
    /// </remarks>
    internal static CohortRegistrySample SampleFor(
        CohortManifest manifest,
        CohortEntry entry,
        CohortEntrySummary summary,
        string outcome,
        string operatorAlias,
        bool subjectHeldElsewhere,
        string observedAtUtc,
        Spent before)
    {
        var subjectKey = CohortRegistry.SubjectKeyOf(entry);
        var draft = new CohortRegistrySample
        {
            SubjectKey = subjectKey,
            SampleKey = CohortRegistry.SampleKeyOf(subjectKey, manifest.CohortId, entry.EntryId, summary.AuditSha256),
            RepositoryId = CohortRegistry.RepositoryIdOf(entry),
            PullRequestId = entry.PullRequestId,
            IterationId = entry.IterationId,
            SourceCommit = entry.SourceCommit,
            TargetRefName = entry.TargetRefName,
            RunRoot = entry.OutputRoot,
            ManifestContractVersion = CohortManifest.ContractVersionValue,
            ManifestSha256 = manifest.ManifestSha256,
            ToolkitHead = manifest.ToolkitHead,
            CohortId = manifest.CohortId,
            EntryId = entry.EntryId,
            AuthorizationKind = manifest.Execution.AuthorizationKind,
            AuthorizedBy = operatorAlias.Length == 0 ? "none" : operatorAlias,
            TerminalState = summary.PreparationFinalState,
            TerminalOutcome = outcome,
            RealModelStarts = summary.ModelStartCount,
            RealVerifierAssignments = summary.VerifierAssignmentCount,
            ProviderWrites = summary.ProviderWriteCount,
            WriteToolInvocations = summary.WriteToolInvocationCount,
            WallClockSeconds = summary.WallClockSeconds,
            CensusComplete = summary.ModelStartUnmeasuredAllowance == 0 && summary.VerifierAssignmentUnmeasuredAllowance == 0,
            BudgetCompliant = before.ModelStarts + summary.ModelStartCount <= manifest.Budgets.MaximumModelStarts
                && before.VerifierAssignments + summary.VerifierAssignmentCount <= manifest.Budgets.MaximumVerifierAssignments
                && before.WallClockSeconds + summary.WallClockSeconds <= manifest.Budgets.MaximumWallClockSeconds,
            AuditSha256 = summary.AuditSha256,
            ObservedAtUtc = observedAtUtc.Length == 0 ? "none" : observedAtUtc,
            CountsTowardThreshold = false,
            Classification = CohortRegistryClassifications.DiagnosticMode
        };
        var mode = manifest.Registry?.Mode ?? CohortRegistryModes.Diagnostic;
        var (counts, classification) = Classify(
            new Criteria(mode, manifest.Execution.Target),
            draft,
            subjectHeldElsewhere);
        return draft with { CountsTowardThreshold = counts, Classification = classification };
    }

    /// <summary>
    /// The row an entry leaves when it ended and its own evidence could not be read.
    /// </summary>
    /// <remarks>
    /// Composed from the journal alone, because the journal is the one thing still
    /// readable: it is signed, it is written before the child starts and again when
    /// the child is gone, and it carries the counters the ending was committed with.
    ///
    /// It exists so the subject is held. An entry only reaches this state after its
    /// preparation has run, so the pull request really was put in front of whatever
    /// the run started; a subject with no row would be offered again by the next
    /// selection as though nothing had ever touched it. The row never counts, and it
    /// counts as an observation, so the honest failure is an under-count.
    /// </remarks>
    /// <summary>
    /// The row a cohort root that committed no journal leaves behind.
    /// </summary>
    /// <remarks>
    /// Without a journal there is no committed intent, no authorization and no
    /// digest to hold an entry's artifacts to, so nothing about what that root did
    /// can be asserted. What CAN be asserted is that the subject was declared and
    /// must not be handed out as fresh. The row holds it, counts toward nothing, and
    /// says in its classification that the evidence was not readable - which is
    /// exactly true, and is a claim about the row rather than an open question about
    /// the account, so it excludes the pull request without wedging the gate.
    /// </remarks>
    internal static CohortRegistrySample UnlaunchedSampleFor(CohortManifest manifest, CohortEntry entry)
    {
        var subjectKey = CohortRegistry.SubjectKeyOf(entry);
        return new CohortRegistrySample
        {
            SubjectKey = subjectKey,
            // Keyed on the manifest digest, because no audit was read and none can
            // be. Two rebuilds over the same root produce the same key.
            SampleKey = CohortRegistry.SampleKeyOf(subjectKey, manifest.CohortId, entry.EntryId, manifest.ManifestSha256),
            RepositoryId = CohortRegistry.RepositoryIdOf(entry),
            PullRequestId = entry.PullRequestId,
            IterationId = entry.IterationId,
            SourceCommit = entry.SourceCommit,
            TargetRefName = entry.TargetRefName,
            RunRoot = entry.OutputRoot,
            ManifestContractVersion = CohortManifest.ContractVersionValue,
            ManifestSha256 = manifest.ManifestSha256,
            ToolkitHead = manifest.ToolkitHead,
            CohortId = manifest.CohortId,
            EntryId = entry.EntryId,
            AuthorizationKind = manifest.Execution.AuthorizationKind,
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
            AuditSha256 = manifest.ManifestSha256,
            ObservedAtUtc = "none",
            CountsTowardThreshold = false,
            Classification = CohortRegistryClassifications.EvidenceUnreadable
        };
    }

    internal static CohortRegistrySample UnreadableSampleFor(
        CohortManifest manifest,
        CohortEntry entry,
        CohortEntryRecord record,
        string operatorAlias)
    {
        var subjectKey = CohortRegistry.SubjectKeyOf(entry);
        return new CohortRegistrySample
        {
            SubjectKey = subjectKey,
            SampleKey = CohortRegistry.SampleKeyOf(subjectKey, manifest.CohortId, entry.EntryId, record.AuditSha256),
            RepositoryId = CohortRegistry.RepositoryIdOf(entry),
            PullRequestId = entry.PullRequestId,
            IterationId = entry.IterationId,
            SourceCommit = entry.SourceCommit,
            TargetRefName = entry.TargetRefName,
            RunRoot = entry.OutputRoot,
            ManifestContractVersion = CohortManifest.ContractVersionValue,
            ManifestSha256 = manifest.ManifestSha256,
            ToolkitHead = manifest.ToolkitHead,
            CohortId = manifest.CohortId,
            EntryId = entry.EntryId,
            AuthorizationKind = manifest.Execution.AuthorizationKind,
            AuthorizedBy = operatorAlias.Length == 0 ? "none" : operatorAlias,
            TerminalState = "unknown",
            TerminalOutcome = record.Outcome,
            RealModelStarts = record.ModelStartCount,
            RealVerifierAssignments = record.VerifierAssignmentCount,
            ProviderWrites = record.ProviderWriteCount,
            WriteToolInvocations = record.WriteToolInvocationCount,
            WallClockSeconds = record.ElapsedSeconds,
            // Nothing about this row is a complete measurement, and saying otherwise
            // would let a later reader treat an unread run as an exactly known one.
            CensusComplete = false,
            BudgetCompliant = false,
            AuditSha256 = record.AuditSha256,
            ObservedAtUtc = record.EndedAtUtc.Length == 0 ? "none" : record.EndedAtUtc,
            CountsTowardThreshold = false,
            Classification = CohortRegistryClassifications.EvidenceUnreadable
        };
    }
}
