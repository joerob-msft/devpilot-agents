using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The versioned request that binds one shadow preparation to one subject.
/// </summary>
/// <remarks>
/// Everything the run is allowed to assume arrives here, in a file, once. There
/// is no environment fallback and no default for anything identifying: a run
/// that cannot say which toolkit head, which pull request, which iteration and
/// which three commits it is preparing has no business preparing anything, and
/// an omitted field is refused rather than filled in.
/// </remarks>
internal sealed record CoordinatorRequest
{
    internal const string ContractVersionValue = "devpilot.shadow-run-coordinator.request.v2";
    internal const string KindValue = "shadow-run-preparation";

    /// <summary>
    /// The slot names this build supervises, in the only order it supervises
    /// them, and the only cardinality it accepts.
    /// </summary>
    /// <remarks>
    /// Both are declared when the request is written, or neither is. A run set
    /// whose second slot appears after the first has already run is a set whose
    /// size changed under a signature, and the whole point of declaring the pair
    /// up front is that the declaration, the plan digest and the request digest
    /// all describe the same two runs from the moment anything is sealed.
    /// </remarks>
    internal static readonly string[] DeclaredSlotNames = ["slot1", "slot2"];

    internal const string FirstSlotName = "slot1";

    internal const string SecondSlotName = "slot2";

    internal const int DeclaredSlotCount = 2;

    internal required string ContractVersion { get; init; }

    internal required string Kind { get; init; }

    internal required string CorrelationId { get; init; }

    internal required string ToolkitRoot { get; init; }

    internal required string ToolkitHead { get; init; }

    internal required string Organization { get; init; }

    internal required string Project { get; init; }

    internal required string Repository { get; init; }

    internal required int PullRequestId { get; init; }

    internal required int IterationId { get; init; }

    internal required string SourceCommit { get; init; }

    internal required string CommonCommit { get; init; }

    internal required string TargetCommit { get; init; }

    internal required string ConfigSha256 { get; init; }

    internal required string PromptSha256 { get; init; }

    internal required string SchemaSha256 { get; init; }

    internal required string CorpusRoot { get; init; }

    internal required string CorpusIndexSha256 { get; init; }

    internal required string CorpusRecipePath { get; init; }

    /// <summary>The caller-declared changed-path census this preparation publishes.</summary>
    internal required string ChangedPathsPath { get; init; }

    internal required string OutputRoot { get; init; }

    internal required string PowerShellPath { get; init; }

    internal required int ChildTimeoutSeconds { get; init; }

    internal required string OperatorAlias { get; init; }

    internal required string ReviewerConfigPath { get; init; }

    internal required string ReviewerRepositoryPath { get; init; }

    internal required string ExpectedCommit { get; init; }

    internal required string RequiredRef { get; init; }

    internal required int PlannedRunCount { get; init; }

    internal required string RunSetKeyPath { get; init; }

    /// <summary>The digest of the exact request bytes, so state cannot be resumed under a different request.</summary>
    internal required string RequestSha256 { get; init; }

    /// <summary>
    /// The two-slot supervision authorization, or null when this request does not
    /// carry one.
    /// </summary>
    /// <remarks>
    /// Optional in one direction only. Absent means the request authorizes no
    /// launch at all, which is the PowerShell rollback posture; it is not a field
    /// being defaulted, it is an authorization that was never given.
    /// Present-and-disabled says the same thing explicitly. Only a present
    /// section carrying an explicit true selects the typed slot path.
    ///
    /// A present section declares BOTH slots and the reconciliation that closes
    /// them, in one file, digested as a unit. There is no way to declare one slot
    /// now and the other later: the state record binds the request digest, so a
    /// request that grew a slot is a different request and refuses to resume.
    /// </remarks>
    internal SlotSetAuthorization? Slots { get; init; }

    /// <summary>
    /// The authorization to build this run's corpus, or null when the caller
    /// supplied a corpus that already exists.
    /// </summary>
    /// <remarks>
    /// Optional in the same one direction as <see cref="Slot"/>. Absent means the
    /// corpus at <see cref="CorpusRoot"/> was produced by something else - the
    /// PowerShell fixture path, an operator, an earlier run - and this run only
    /// validates it. That is the retained rollback default and it is what every
    /// request written before this slice says.
    ///
    /// Present-and-enabled says the opposite: the corpus does not exist yet, this
    /// run builds it from the declared immutable sources, and a corpus root that
    /// already exists is a refusal rather than something to reuse. Getting those
    /// two postures confused is the whole failure this section exists to prevent,
    /// so neither is ever inferred from whether a directory happens to be there.
    /// </remarks>
    internal CorpusStageAuthorization? CorpusStage { get; init; }

    internal string CoordinatorRoot => Path.Combine(OutputRoot, "coordinator");

    internal string StatePath => Path.Combine(CoordinatorRoot, "state.json");

    internal string StateKeyPath => Path.Combine(CoordinatorRoot, "state.key");

    internal string LeasePath => Path.Combine(CoordinatorRoot, "run.lease");

    internal string AuditPath => Path.Combine(CoordinatorRoot, "audit.json");

    internal string ExchangeRoot => Path.Combine(CoordinatorRoot, "exchange");

    /// <summary>
    /// Where the signed intent to start a child is committed, before the child
    /// exists. Kept apart from the exchange because these records outlive the
    /// step they describe: they are the only evidence a coordinator killed
    /// between deciding to launch and observing what it launched leaves behind.
    /// </summary>
    internal string LaunchIntentRoot => Path.Combine(CoordinatorRoot, "intents");

    internal string LogRoot => Path.Combine(CoordinatorRoot, "logs");

    internal string StageArtifactRoot => Path.Combine(OutputRoot, "stage-artifacts");

    internal string ReplayRoot => Path.Combine(OutputRoot, "replay-root");

    internal string QualificationRoot => Path.Combine(OutputRoot, "qualification");

    /// <summary>Where the strict versioned reconciliation exchange lives.</summary>
    internal string ReconciliationRoot => Path.Combine(CoordinatorRoot, "reconciliation");

    /// <summary>The strict versioned file this coordinator hands the reconciliation.</summary>
    internal string ReconciliationRequestPath => Path.Combine(ReconciliationRoot, "reconciliation-request.json");

    /// <summary>The strict versioned file the reconciliation hands back.</summary>
    internal string ReconciliationSummaryPath => Path.Combine(ReconciliationRoot, "reconciliation-summary.json");

    /// <summary>Where the strict versioned delivery exchange lives.</summary>
    internal string DeliveryRoot => Path.Combine(CoordinatorRoot, "delivery");

    /// <summary>The strict versioned file this coordinator hands the delivery evaluation.</summary>
    internal string DeliveryRequestPath => Path.Combine(DeliveryRoot, "delivery-request.json");

    /// <summary>The strict versioned file the delivery evaluation hands back.</summary>
    internal string DeliverySummaryPath => Path.Combine(DeliveryRoot, "delivery-summary.json");

    internal static CoordinatorRequest Load(string path)
    {
        const string label = "shadow run coordinator request";
        // One acquisition. The request is both obeyed and digested, and reading it
        // twice would leave a window in which the bytes that were obeyed and the
        // bytes the digest attests to are not the same bytes - and would put an
        // unguarded read where a refusal is owed, so a request that vanished
        // mid-load would arrive at the caller as a filesystem fault.
        var bytes = StrictJson.ReadFileBytes(path, label);
        var root = StrictJson.ReadObjectBytes(bytes, path, label);
        StrictJson.RequireNoUnknownFields(
            root,
            label,
            "contractVersion",
            "kind",
            "correlationId",
            "toolkit",
            "subject",
            "digests",
            "corpus",
            "output",
            "children",
            "qualification",
            "slots",
            "corpusStage");

        var contractVersion = StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, label);
        var kind = StrictJson.RequireLiteral(root, "kind", KindValue, label);
        var correlationId = StrictJson.RequireString(root, "correlationId", label);
        RequireCorrelationShape(correlationId);

        var toolkit = StrictJson.RequireObject(root, "toolkit", label);
        StrictJson.RequireNoUnknownFields(toolkit, label + " toolkit", "repositoryRoot", "head");

        var subject = StrictJson.RequireObject(root, "subject", label);
        StrictJson.RequireNoUnknownFields(
            subject,
            label + " subject",
            "organization",
            "project",
            "repository",
            "pullRequestId",
            "iterationId",
            "sourceCommit",
            "commonCommit",
            "targetCommit");

        var digests = StrictJson.RequireObject(root, "digests", label);
        StrictJson.RequireNoUnknownFields(digests, label + " digests", "configSha256", "promptSha256", "schemaSha256");

        var corpus = StrictJson.RequireObject(root, "corpus", label);
        StrictJson.RequireNoUnknownFields(corpus, label + " corpus", "root", "indexSha256", "recipePath", "changedPathsPath");

        var output = StrictJson.RequireObject(root, "output", label);
        StrictJson.RequireNoUnknownFields(output, label + " output", "root");

        var children = StrictJson.RequireObject(root, "children", label);
        StrictJson.RequireNoUnknownFields(children, label + " children", "powerShellPath", "timeoutSeconds");

        var qualification = StrictJson.RequireObject(root, "qualification", label);
        StrictJson.RequireNoUnknownFields(
            qualification,
            label + " qualification",
            "operatorAlias",
            "reviewerConfigPath",
            "reviewerRepositoryPath",
            "expectedCommit",
            "requiredRef",
            "plannedRunCount",
            "runSetKeyPath");

        // Optional, and read fail-closed when present: a section that exists must
        // be complete and well shaped. The only thing absence buys is "no
        // authorization", never a default value for one.
        SlotSetAuthorization? slots = null;
        if (root.TryGetProperty("slots", out var slotsNode))
        {
            slots = SlotSetAuthorization.Read(slotsNode, label + " slots");
        }

        CorpusStageAuthorization? corpusStage = null;
        if (root.TryGetProperty("corpusStage", out var corpusStageNode))
        {
            corpusStage = CorpusStageAuthorization.Read(corpusStageNode, label + " corpusStage");
        }

        var plannedRunCount = StrictJson.RequireInt(qualification, "plannedRunCount", label + " qualification", 2, 16);
        // Exact, not merely compatible. A set that plans three runs while the
        // request declares two would leave a slot nobody supervises and a
        // reconciliation that closes over a set it never saw whole.
        if (slots is not null && plannedRunCount != slots.Declared.Count)
        {
            throw new ContractException(
                $"The request plans {plannedRunCount.ToString(System.Globalization.CultureInfo.InvariantCulture)} run(s) and declares " +
                $"{slots.Declared.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)} slot(s). A declared run set is the slots it declares, exactly.");
        }
        return new CoordinatorRequest
        {            ContractVersion = contractVersion,
            Kind = kind,
            CorrelationId = correlationId,
            ToolkitRoot = StrictJson.RequireString(toolkit, "repositoryRoot", label + " toolkit"),
            ToolkitHead = StrictJson.RequireHex(toolkit, "head", label + " toolkit", 40),
            Organization = StrictJson.RequireString(subject, "organization", label + " subject"),
            Project = StrictJson.RequireString(subject, "project", label + " subject"),
            Repository = StrictJson.RequireString(subject, "repository", label + " subject"),
            PullRequestId = StrictJson.RequireInt(subject, "pullRequestId", label + " subject", 1, int.MaxValue),
            IterationId = StrictJson.RequireInt(subject, "iterationId", label + " subject", 1, 4096),
            SourceCommit = StrictJson.RequireHex(subject, "sourceCommit", label + " subject", 40),
            CommonCommit = StrictJson.RequireHex(subject, "commonCommit", label + " subject", 40),
            TargetCommit = StrictJson.RequireHex(subject, "targetCommit", label + " subject", 40),
            ConfigSha256 = StrictJson.RequireHex(digests, "configSha256", label + " digests", 64),
            PromptSha256 = StrictJson.RequireHex(digests, "promptSha256", label + " digests", 64),
            SchemaSha256 = StrictJson.RequireHex(digests, "schemaSha256", label + " digests", 64),
            CorpusRoot = StrictJson.RequireString(corpus, "root", label + " corpus"),
            CorpusIndexSha256 = StrictJson.RequireHex(corpus, "indexSha256", label + " corpus", 64),
            CorpusRecipePath = StrictJson.RequireString(corpus, "recipePath", label + " corpus"),
            ChangedPathsPath = StrictJson.RequireString(corpus, "changedPathsPath", label + " corpus"),
            OutputRoot = StrictJson.RequireString(output, "root", label + " output"),
            PowerShellPath = StrictJson.RequireString(children, "powerShellPath", label + " children"),
            ChildTimeoutSeconds = StrictJson.RequireInt(children, "timeoutSeconds", label + " children", 1, 14400),
            OperatorAlias = StrictJson.RequireString(qualification, "operatorAlias", label + " qualification"),
            ReviewerConfigPath = StrictJson.RequireString(qualification, "reviewerConfigPath", label + " qualification"),
            ReviewerRepositoryPath = StrictJson.RequireString(qualification, "reviewerRepositoryPath", label + " qualification"),
            ExpectedCommit = StrictJson.RequireHex(qualification, "expectedCommit", label + " qualification", 40),
            RequiredRef = StrictJson.RequireString(qualification, "requiredRef", label + " qualification"),
            PlannedRunCount = plannedRunCount,
            RunSetKeyPath = StrictJson.RequireString(qualification, "runSetKeyPath", label + " qualification"),
            RequestSha256 = CanonicalJson.Sha256Hex(bytes),
            Slots = slots,
            CorpusStage = corpusStage
        };
    }

    /// <summary>
    /// The correlation identifier goes into every file and every log line, so it
    /// is constrained to something that cannot inject a path separator, a shell
    /// metacharacter, or a newline into either.
    /// </summary>
    private static void RequireCorrelationShape(string correlationId)
    {
        if (correlationId.Length is < 8 or > 64)
        {
            throw new ContractException("The shadow run coordinator request field 'correlationId' must be 8 to 64 characters.");
        }
        foreach (var character in correlationId)
        {
            var ok = character is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '-';
            if (!ok)
            {
                throw new ContractException("The shadow run coordinator request field 'correlationId' accepts only letters, digits and hyphens.");
            }
        }
    }

    /// <summary>The subject binding, recorded in state and audit so a resume cannot drift onto another pull request.</summary>
    internal MapNode DescribeSubject() => new MapNode()
        .Set("organization", Organization)
        .Set("project", Project)
        .Set("repository", Repository)
        .Set("pullRequestId", PullRequestId)
        .Set("iterationId", IterationId)
        .Set("sourceCommit", SourceCommit)
        .Set("commonCommit", CommonCommit)
        .Set("targetCommit", TargetCommit);

    internal MapNode DescribeDigests() => new MapNode()
        .Set("configSha256", ConfigSha256)
        .Set("promptSha256", PromptSha256)
        .Set("schemaSha256", SchemaSha256)
        .Set("corpusIndexSha256", CorpusIndexSha256);

    /// <summary>
    /// The slot set this run holds, or a refusal naming why it holds none. Every
    /// slot and reconciliation transition asks for it this way, so there is
    /// exactly one place where "no authorization" becomes a refusal.
    /// </summary>
    internal SlotSetAuthorization RequireSlotSet()
    {
        if (Slots is null)
        {
            throw new ContractException(
                "This request carries no 'slots' section, so it authorizes no launch. " +
                "The PowerShell qualification path remains the default; add an explicit slots section with " +
                "'shadowSlotsEnabled': true to select the typed supervisor.");
        }
        if (!Slots.ShadowSlotsEnabled)
        {
            throw new ContractException(
                "The request's slots section sets 'shadowSlotsEnabled' to false, which is an explicit refusal to " +
                "launch through the typed supervisor. Nothing is launched.");
        }
        return Slots;
    }

    /// <summary>The declared slot at an ordinal, or a refusal. Ordinals are one-based.</summary>
    internal SlotAuthorization RequireSlot(int ordinal)
    {
        var set = RequireSlotSet();
        foreach (var slot in set.Declared)
        {
            if (slot.Ordinal == ordinal)
            {
                return slot;
            }
        }
        throw new ContractException(
            $"This request declares no slot at ordinal {ordinal.ToString(System.Globalization.CultureInfo.InvariantCulture)}; " +
            $"it declares {string.Join(", ", set.Declared.Select(entry => "'" + entry.Name + "'"))}.");
    }

    /// <summary>
    /// The reviewer agent every declared slot names. Read through the set so that
    /// a request naming two different agents is refused once, here, rather than
    /// discovered when the second slot fails to reproduce the first's plan.
    /// </summary>
    internal string SlotReviewerScriptPath => Slots?.ReviewerScriptPath ?? string.Empty;

    /// <summary>
    /// Whether this run builds its own corpus. Absent and present-and-disabled
    /// both mean no, and both are read the same way everywhere.
    /// </summary>
    internal bool CorpusStagingRequested => CorpusStage is { StagingEnabled: true };

    /// <summary>
    /// The corpus staging authorization this run holds, or a refusal naming why
    /// it holds none.
    /// </summary>
    internal CorpusStageAuthorization RequireCorpusStaging()
    {
        if (CorpusStage is null)
        {
            throw new ContractException(
                "This request carries no 'corpusStage' section, so it authorizes no corpus construction. " +
                "The corpus named by 'corpus.root' is expected to exist already; add an explicit corpusStage " +
                "section with 'stagingEnabled': true to have the typed control plane build it.");
        }
        if (!CorpusStage.StagingEnabled)
        {
            throw new ContractException(
                "The request's corpusStage section sets 'stagingEnabled' to false, which is an explicit refusal to " +
                "build a corpus. Nothing is staged and nothing is published.");
        }
        return CorpusStage;
    }
}

/// <summary>
/// The authorization to build exactly one corpus from declared immutable
/// sources.
/// </summary>
/// <remarks>
/// Deliberately thin. It says whether to stage, which declaration to stage from,
/// and what that declaration's bytes must digest to - and nothing else. Every
/// fact about what the corpus contains lives in the declaration file, where it
/// is digested as a unit, so a caller cannot move one payload into the request
/// and have it escape that digest.
/// </remarks>
internal sealed record CorpusStageAuthorization
{
    internal required bool StagingEnabled { get; init; }

    /// <summary>The corpus stage declaration this run builds from.</summary>
    internal required string RequestPath { get; init; }

    /// <summary>
    /// The declaration's exact bytes, bound here so that a resumed run cannot be
    /// pointed at an edited declaration under the same path.
    /// </summary>
    internal required string RequestSha256 { get; init; }

    internal static CorpusStageAuthorization Read(JsonElement node, string label)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(node, label, "stagingEnabled", "requestPath", "requestSha256");
        return new CorpusStageAuthorization
        {
            StagingEnabled = StrictJson.RequireBool(node, "stagingEnabled", label),
            RequestPath = StrictJson.RequireString(node, "requestPath", label),
            RequestSha256 = StrictJson.RequireHex(node, "requestSha256", label, 64)
        };
    }

    internal MapNode Describe() => new MapNode()
        .Set("stagingEnabled", StagingEnabled)
        .Set("requestPath", RequestPath)
        .Set("requestSha256", RequestSha256);
}

/// <summary>
/// The authorization for the whole supervised set: both slots, in order, the
/// reconciliation that closes them, and the preview-only delivery decision that
/// may follow it.
/// </summary>
/// <remarks>
/// Declared as a unit because it is sealed as a unit. The request digest covers
/// this section whole, and the durable record binds that digest, so there is no
/// resume under which a set can acquire a third slot, lose its second, or gain a
/// reconciliation or a delivery it was not written with.
///
/// Nothing here decides anything about a review. The reviewer agent is named
/// once for the set, because the qualification plan seals one agent for the set
/// and two slots naming two agents could never reproduce one plan.
/// </remarks>
internal sealed record SlotSetAuthorization
{
    internal required bool ShadowSlotsEnabled { get; init; }

    /// <summary>The declared slots, in ordinal order, and there are exactly two.</summary>
    internal required IReadOnlyList<SlotAuthorization> Declared { get; init; }

    internal required ReconciliationAuthorization Reconciliation { get; init; }

    /// <summary>
    /// The preview-only delivery decision this set was declared with, or null when
    /// the request was written without one.
    /// </summary>
    /// <remarks>
    /// Optional in exactly one direction. A request that omits the section
    /// authorizes no delivery at all and every delivery transition refuses,
    /// which is what keeps the reviewed PowerShell path the rollback default and
    /// leaves every earlier slice's request valid unchanged. A request that
    /// carries the section carries it whole, from creation, sealed inside the
    /// same request digest as the slots it closes over - so no resume can add a
    /// delivery to a set that was not declared with one.
    /// </remarks>
    internal DeliveryAuthorization? Delivery { get; init; }

    /// <summary>The one agent script the whole set names.</summary>
    internal string ReviewerScriptPath => Declared[0].ReviewerScriptPath;

    internal static SlotSetAuthorization Read(JsonElement node, string label)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(node, label, "shadowSlotsEnabled", "declared", "reconciliation", "delivery");

        var declaredNodes = StrictJson.RequireArray(node, "declared", label);
        if (declaredNodes.Count != CoordinatorRequest.DeclaredSlotCount)
        {
            throw new ContractException(
                $"The {label} declares {declaredNodes.Count.ToString(CultureInfo.InvariantCulture)} slot(s). " +
                $"This build supervises exactly {CoordinatorRequest.DeclaredSlotCount.ToString(CultureInfo.InvariantCulture)}, " +
                $"named {string.Join(" then ", CoordinatorRequest.DeclaredSlotNames)}, and both are declared when the request is written.");
        }
        var declared = new List<SlotAuthorization>();
        for (var index = 0; index < declaredNodes.Count; index++)
        {
            var expected = CoordinatorRequest.DeclaredSlotNames[index];
            declared.Add(SlotAuthorization.Read(declaredNodes[index], $"{label} declared[{index.ToString(CultureInfo.InvariantCulture)}]", expected, index + 1));
        }

        // One agent for the set. Read as an equality rather than as a preference
        // so that the refusal names the disagreement instead of silently
        // preferring the first slot's answer.
        if (!string.Equals(declared[0].ReviewerScriptPath, declared[1].ReviewerScriptPath, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} names '{declared[0].ReviewerScriptPath}' for '{declared[0].Name}' and '{declared[1].ReviewerScriptPath}' for '{declared[1].Name}'. " +
                "One qualification plan seals one agent, so a set whose slots name two could never reproduce the plan it was declared under.");
        }
        // Two slots that share a state root are one slot run twice into the same
        // place. The names are declared rather than derived, so the collision is
        // caught in the request instead of when the second run overwrites the
        // first's evidence.
        if (string.Equals(declared[0].StateDirName, declared[1].StateDirName, StringComparison.OrdinalIgnoreCase))
        {
            throw new ContractException($"The {label} gives both slots the state root '{declared[0].StateDirName}'; two runs that share a state root are not two runs.");
        }
        if (string.Equals(declared[0].TerminalName, declared[1].TerminalName, StringComparison.OrdinalIgnoreCase))
        {
            throw new ContractException($"The {label} gives both slots the terminal artifact '{declared[0].TerminalName}'; the second would overwrite the first's evidence.");
        }

        var reconciliation = ReconciliationAuthorization.Read(
            StrictJson.RequireObject(node, "reconciliation", label),
            label + " reconciliation");
        if (reconciliation.RequiredRunCount != declared.Count)
        {
            throw new ContractException(
                $"The {label} reconciliation requires {reconciliation.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the set declares " +
                $"{declared.Count.ToString(CultureInfo.InvariantCulture)}. A reconciliation that closes over fewer runs than were declared is closing over a set nobody declared.");
        }

        DeliveryAuthorization? delivery = null;
        if (node.TryGetProperty("delivery", out var deliveryNode))
        {
            delivery = DeliveryAuthorization.Read(deliveryNode, label + " delivery");
            if (delivery.RequiredRunCount != declared.Count)
            {
                throw new ContractException(
                    $"The {label} delivery covers {delivery.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the set declares " +
                    $"{declared.Count.ToString(CultureInfo.InvariantCulture)}. A delivery decision over fewer runs than were declared is a decision about a set nobody declared.");
            }
            // Two evaluations writing into one directory would leave the
            // reconciliation's artifacts and the delivery's indistinguishable by
            // path, and the delivery is verified by pinning the files it
            // produced. Refused in the request rather than discovered later.
            if (string.Equals(delivery.OutputDirectory, reconciliation.OutputDirectory, StringComparison.OrdinalIgnoreCase))
            {
                throw new ContractException(
                    $"The {label} gives the reconciliation and the delivery the same output directory '{delivery.OutputDirectory}'; " +
                    "each evaluation's artifacts must be distinguishable from the other's.");
            }
        }

        return new SlotSetAuthorization
        {
            ShadowSlotsEnabled = StrictJson.RequireBool(node, "shadowSlotsEnabled", label),
            Declared = declared,
            Reconciliation = reconciliation,
            Delivery = delivery
        };
    }

    internal MapNode Describe()
    {
        var slots = new ListNode();
        foreach (var slot in Declared)
        {
            slots.Add(slot.Describe());
        }
        return new MapNode()
            .Set("declaredSlotCount", Declared.Count)
            .Set("declared", slots)
            .Set("reconciliation", Reconciliation.Describe())
            .Set("deliveryDeclared", Delivery is not null)
            .Set("delivery", Delivery is null ? Node.Null() : Delivery.Describe());
    }

    /// <summary>
    /// The delivery authorization this set holds, or a refusal naming why it holds
    /// none. Every delivery transition asks for it this way.
    /// </summary>
    internal DeliveryAuthorization RequireDelivery()
    {
        if (Delivery is null)
        {
            throw new ContractException(
                "This request's slots section carries no 'delivery' section, so it authorizes no delivery decision. " +
                "The reviewed PowerShell delivery path remains the default; a delivery is declared when the request is " +
                "written or it is not declared at all.");
        }
        return Delivery.Require();
    }
}

/// <summary>
/// The authorization for exactly one supervised slot.
/// </summary>
/// <remarks>
/// Everything here is authorization, binding or supervision. There is no prompt,
/// no candidate rule and no verdict rule, and the one thing here that touches a
/// model is opaque: <see cref="ModelPlan"/> carries argument strings this
/// coordinator forwards and digests but never reads, compares by value, or
/// branches on. Which models a slot runs is the reviewed plan's decision, sealed
/// into the plan digest; what a slot may do here is say that it expects that
/// decision to contain particular sealed arguments, and let the reviewed side
/// answer.
///
/// The deadlines are NOT here. They come from the signed qualification plan, so
/// a caller cannot widen a slot's budget by editing its own request; what the
/// request may set is the supervision grace - how long the typed supervisor
/// waits past the plan's own deadline before it concludes the PowerShell owner
/// failed to terminate its own run and kills the tree.
/// </remarks>
internal sealed record SlotAuthorization
{
    internal required string Name { get; init; }

    /// <summary>One-based position in the declared order, which is the order slots run in.</summary>
    internal required int Ordinal { get; init; }

    /// <summary>The agent script the qualification plan names, bound by the plan digest.</summary>
    internal required string ReviewerScriptPath { get; init; }

    /// <summary>The single-use launch-authorization token this slot presents.</summary>
    internal required string LaunchAuthorizationTokenPath { get; init; }

    internal required int SupervisionGraceSeconds { get; init; }

    /// <summary>The leaf name this slot's state root must carry.</summary>
    internal required string StateDirName { get; init; }

    /// <summary>The leaf name this slot's terminal artifact must carry.</summary>
    internal required string TerminalName { get; init; }

    internal required SlotModelPlan ModelPlan { get; init; }

    internal static SlotAuthorization Read(JsonElement node, string label, string expectedName, int ordinal)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "name",
            "reviewerScriptPath",
            "launchAuthorizationTokenPath",
            "supervisionGraceSeconds",
            "stateDirName",
            "terminalName",
            "modelPlan");

        var name = StrictJson.RequireString(node, "name", label);
        // Position and name are checked against each other rather than either
        // being inferred. A set whose second entry calls itself slot1 would
        // otherwise run the same slot twice under two authorizations.
        if (!string.Equals(name, expectedName, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} names slot '{name}' at the position reserved for '{expectedName}'. " +
                $"This build supervises {string.Join(" then ", CoordinatorRequest.DeclaredSlotNames)}, in that order.");
        }
        return new SlotAuthorization
        {
            Name = name,
            Ordinal = ordinal,
            ReviewerScriptPath = StrictJson.RequireString(node, "reviewerScriptPath", label),
            LaunchAuthorizationTokenPath = StrictJson.RequireString(node, "launchAuthorizationTokenPath", label),
            // A grace of zero would mean the supervisor kills at the same instant
            // the plan's own deadline fires, and the race decides whether the
            // immutable terminal artifact gets written at all. The floor makes the
            // PowerShell owner the writer of its own terminal in every ordering.
            SupervisionGraceSeconds = StrictJson.RequireInt(node, "supervisionGraceSeconds", label, 30, 3600),
            StateDirName = RequireLeafName(node, "stateDirName", label),
            TerminalName = RequireLeafName(node, "terminalName", label),
            ModelPlan = SlotModelPlan.Read(StrictJson.RequireObject(node, "modelPlan", label), label + " modelPlan")
        };
    }

    /// <summary>
    /// A single path component, refused if it could climb out of the directory
    /// the reviewed plan places a slot's evidence in.
    /// </summary>
    private static string RequireLeafName(JsonElement node, string field, string label)
    {
        var value = StrictJson.RequireString(node, field, label);
        if (value.Length is 0 or > 128)
        {
            throw new ContractException($"The {label} field '{field}' must be 1 to 128 characters.");
        }
        foreach (var character in value)
        {
            var ok = character is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '-' or '_' or '.';
            if (!ok)
            {
                throw new ContractException($"The {label} field '{field}' accepts only letters, digits, hyphen, underscore and dot; it is a single path component, not a path.");
            }
        }
        if (value is "." or ".." || value.Contains("..", StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} field '{field}' is '{value}', which is not a single path component.");
        }
        return value;
    }

    internal MapNode Describe() => new MapNode()
        .Set("name", Name)
        .Set("ordinal", Ordinal)
        .Set("reviewerScriptPath", ReviewerScriptPath)
        .Set("supervisionGraceSeconds", SupervisionGraceSeconds)
        .Set("stateDirName", StateDirName)
        .Set("terminalName", TerminalName)
        .Set("modelPlan", ModelPlan.Describe());
}

/// <summary>
/// What a slot expects its sealed plan arguments to contain, as opaque text.
/// </summary>
/// <remarks>
/// This is the one place a model name may reach the typed control plane, and it
/// reaches it as a string in a signed request that this code forwards and
/// digests without reading. There is no comparison by value here, no lookup
/// table, no selection and no default: the arguments are handed to the reviewed
/// side, which owns what they mean, and the answer comes back as a boolean the
/// reviewed side computed.
///
/// <see cref="BindSealedArguments"/> is explicit rather than inferred from an
/// empty list, because "I declare no expectation" and "I declare an empty
/// expectation" are different statements and only one of them is an authorization
/// to skip a check.
/// </remarks>
internal sealed record SlotModelPlan
{
    internal required bool BindSealedArguments { get; init; }

    /// <summary>Opaque argument text, forwarded verbatim and never interpreted here.</summary>
    internal required IReadOnlyList<string> OpaqueArguments { get; init; }

    internal static SlotModelPlan Read(JsonElement node, string label)
    {
        StrictJson.RequireNoUnknownFields(node, label, "bindSealedArguments", "opaqueArguments");
        var bind = StrictJson.RequireBool(node, "bindSealedArguments", label);
        var arguments = StrictJson.RequireStringArray(node, "opaqueArguments", label);
        if (arguments.Count > 64)
        {
            throw new ContractException($"The {label} carries {arguments.Count.ToString(CultureInfo.InvariantCulture)} opaque argument(s); 64 is the most a slot may declare.");
        }
        foreach (var argument in arguments)
        {
            if (argument.Length is 0 or > 256)
            {
                throw new ContractException($"The {label} carries an opaque argument of {argument.Length.ToString(CultureInfo.InvariantCulture)} characters; each is 1 to 256.");
            }
        }
        if (bind && arguments.Count == 0)
        {
            throw new ContractException(
                $"The {label} asks for its sealed arguments to be bound and declares none. " +
                "An empty expectation binds nothing; say 'bindSealedArguments': false to declare that no binding was asked for.");
        }
        return new SlotModelPlan { BindSealedArguments = bind, OpaqueArguments = arguments };
    }

    /// <summary>The opaque arguments as a list node, for forwarding to the reviewed side.</summary>
    internal ListNode AsList()
    {
        var list = new ListNode();
        foreach (var argument in OpaqueArguments)
        {
            list.Add(argument);
        }
        return list;
    }

    /// <summary>
    /// The record's view of the declaration: whether a binding was asked for,
    /// how many arguments it names, and their digest. The argument text is
    /// deliberately not committed, so a state file never becomes a place to read
    /// a model roster out of.
    /// </summary>
    internal MapNode Describe() => new MapNode()
        .Set("bindSealedArguments", BindSealedArguments)
        .Set("opaqueArgumentCount", OpaqueArguments.Count)
        .Set("opaqueArgumentsSha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(AsList())));
}

/// <summary>
/// The authorization to close a completed set with the reviewed comparison.
/// </summary>
/// <remarks>
/// It carries no rule about what reconciliation should conclude, and it cannot:
/// the comparison is the existing PowerShell tool, the report and the sealed
/// artifact are its outputs, and what this coordinator gets back is a strict
/// versioned summary of status, digests and named counts it copies without
/// reading. There is no delivery in this record: a delivery is a separate,
/// separately-declared authorization that runs after this one and writes
/// nowhere either.
/// </remarks>
internal sealed record ReconciliationAuthorization
{
    internal required bool ReconciliationEnabled { get; init; }

    /// <summary>Where the reviewed comparison writes its report and sealed artifact.</summary>
    internal required string OutputDirectory { get; init; }

    /// <summary>How many runs the comparison is required to cover, which is the declared slot count.</summary>
    internal required int RequiredRunCount { get; init; }

    /// <summary>The single-use authorization the reconciliation presents.</summary>
    internal required string LaunchAuthorizationTokenPath { get; init; }

    internal required int SupervisionGraceSeconds { get; init; }

    internal static ReconciliationAuthorization Read(JsonElement node, string label)
    {
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "reconciliationEnabled",
            "outputDirectory",
            "requiredRunCount",
            "launchAuthorizationTokenPath",
            "supervisionGraceSeconds");
        return new ReconciliationAuthorization
        {
            ReconciliationEnabled = StrictJson.RequireBool(node, "reconciliationEnabled", label),
            OutputDirectory = StrictJson.RequireString(node, "outputDirectory", label),
            RequiredRunCount = StrictJson.RequireInt(node, "requiredRunCount", label, 2, 16),
            LaunchAuthorizationTokenPath = StrictJson.RequireString(node, "launchAuthorizationTokenPath", label),
            SupervisionGraceSeconds = StrictJson.RequireInt(node, "supervisionGraceSeconds", label, 30, 3600)
        };
    }

    /// <summary>
    /// The reconciliation authorization this run holds, or a refusal naming why
    /// it holds none.
    /// </summary>
    internal ReconciliationAuthorization Require()
    {
        if (!ReconciliationEnabled)
        {
            throw new ContractException(
                "The request's reconciliation section sets 'reconciliationEnabled' to false, which is an explicit refusal to " +
                "close this set. The two slots may still run; nothing is reconciled and nothing is delivered.");
        }
        return this;
    }

    internal MapNode Describe() => new MapNode()
        .Set("reconciliationEnabled", ReconciliationEnabled)
        .Set("outputDirectory", OutputDirectory)
        .Set("requiredRunCount", RequiredRunCount)
        .Set("supervisionGraceSeconds", SupervisionGraceSeconds);
}

/// <summary>
/// The authorization to evaluate one delivery decision over a reconciled set,
/// in preview only, writing to no provider.
/// </summary>
/// <remarks>
/// Every field here is a refusal wearing the shape of a setting. The
/// authorization kind is a literal this contract will accept exactly one value
/// for; the three capability flags are literals this contract will accept
/// exactly <c>false</c> for; the write budget is a literal this contract will
/// accept exactly zero for. There is no permissive value to write, so a request
/// asking for a write is not a request this program can load - and that is
/// checked here, at the boundary, before any child of any kind is started.
///
/// The delivery itself is the reviewed PowerShell's. What crosses back into this
/// program is a status word, some digests, and a census of integers, none of
/// which anything here compares to a literal or branches on. This record cannot
/// widen that: it is authorization and binding, and there is no field in it that
/// names a comment, a vote, a thread, a severity or a finding.
/// </remarks>
internal sealed record DeliveryAuthorization
{
    /// <summary>The one authorization kind this build accepts. There is no second one.</summary>
    internal const string PreviewOnlyKind = "PreviewOnly";

    internal required bool DeliveryEnabled { get; init; }

    /// <summary>Always <see cref="PreviewOnlyKind"/>; any other value is refused at load.</summary>
    internal required string AuthorizationKind { get; init; }

    /// <summary>Where the reviewed evaluation writes its decision artifact and report.</summary>
    internal required string OutputDirectory { get; init; }

    /// <summary>How many runs the decision closes over, which is the declared slot count.</summary>
    internal required int RequiredRunCount { get; init; }

    /// <summary>The single-use authorization the delivery presents.</summary>
    internal required string LaunchAuthorizationTokenPath { get; init; }

    internal required int SupervisionGraceSeconds { get; init; }

    internal static DeliveryAuthorization Read(JsonElement node, string label)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "deliveryEnabled",
            "authorizationKind",
            "outputDirectory",
            "requiredRunCount",
            "launchAuthorizationTokenPath",
            "supervisionGraceSeconds",
            "commentsEnabled",
            "votesEnabled",
            "gatesEnabled",
            "providerWriteBudget");

        var kind = StrictJson.RequireString(node, "authorizationKind", label);
        if (!string.Equals(kind, PreviewOnlyKind, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares authorization kind '{kind}'. This build authorizes exactly one kind, " +
                $"'{PreviewOnlyKind}', and there is no transition it could perform under any other.");
        }
        // Read as literals rather than as booleans that happen to be false today.
        // A boolean read would make "true" a value this program accepts and then
        // refuses somewhere downstream; a literal makes it a request that never
        // loads.
        foreach (var capability in new[] { "commentsEnabled", "votesEnabled", "gatesEnabled" })
        {
            if (StrictJson.RequireBool(node, capability, label))
            {
                throw new ContractException(
                    $"The {label} sets '{capability}' to true. Every write capability is off in this build and there " +
                    "is no code path that could honour one, so a request asking for it is refused before anything starts.");
            }
        }
        var writeBudget = StrictJson.RequireInt(node, "providerWriteBudget", label, 0, 0);

        return new DeliveryAuthorization
        {
            DeliveryEnabled = StrictJson.RequireBool(node, "deliveryEnabled", label),
            AuthorizationKind = kind,
            OutputDirectory = StrictJson.RequireString(node, "outputDirectory", label),
            RequiredRunCount = StrictJson.RequireInt(node, "requiredRunCount", label, 2, 16),
            LaunchAuthorizationTokenPath = StrictJson.RequireString(node, "launchAuthorizationTokenPath", label),
            SupervisionGraceSeconds = StrictJson.RequireInt(node, "supervisionGraceSeconds", label, 30, 3600),
            ProviderWriteBudget = writeBudget
        };
    }

    /// <summary>Zero, and refused at load if it is anything else.</summary>
    internal required int ProviderWriteBudget { get; init; }

    /// <summary>
    /// The delivery authorization this run holds, or a refusal naming why it holds
    /// none.
    /// </summary>
    internal DeliveryAuthorization Require()
    {
        if (!DeliveryEnabled)
        {
            throw new ContractException(
                "The request's delivery section sets 'deliveryEnabled' to false, which is an explicit refusal to " +
                "evaluate a delivery decision. The set may still run and reconcile; nothing is evaluated and nothing is written.");
        }
        return this;
    }

    internal MapNode Describe() => new MapNode()
        .Set("deliveryEnabled", DeliveryEnabled)
        .Set("authorizationKind", AuthorizationKind)
        .Set("outputDirectory", OutputDirectory)
        .Set("requiredRunCount", RequiredRunCount)
        .Set("supervisionGraceSeconds", SupervisionGraceSeconds)
        .Set("commentsEnabled", false)
        .Set("votesEnabled", false)
        .Set("gatesEnabled", false)
        .Set("providerWriteBudget", ProviderWriteBudget);
}
