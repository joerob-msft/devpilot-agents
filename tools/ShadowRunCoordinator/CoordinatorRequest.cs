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
    internal const string ContractVersionValue = "devpilot.shadow-run-coordinator.request.v1";
    internal const string KindValue = "shadow-run-preparation";

    /// <summary>The one slot name this build supervises. There is no second slot to name.</summary>
    internal const string SupervisedSlotName = "slot1";

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
    /// The one-slot supervision authorization, or null when this request does not
    /// carry one.
    /// </summary>
    /// <remarks>
    /// The only optional section in this contract, and optional in one direction
    /// only. Absent means the request authorizes no launch at all, which is the
    /// PowerShell rollback posture and the state of every request written for the
    /// preparation slice; it is not a field being defaulted, it is an
    /// authorization that was never given. Present-and-disabled says the same
    /// thing explicitly. Only a present section carrying an explicit true selects
    /// the typed slot path.
    /// </remarks>
    internal SlotAuthorization? Slot { get; init; }

    internal string CoordinatorRoot => Path.Combine(OutputRoot, "coordinator");

    internal string StatePath => Path.Combine(CoordinatorRoot, "state.json");

    internal string StateKeyPath => Path.Combine(CoordinatorRoot, "state.key");

    internal string LeasePath => Path.Combine(CoordinatorRoot, "run.lease");

    internal string AuditPath => Path.Combine(CoordinatorRoot, "audit.json");

    internal string ExchangeRoot => Path.Combine(CoordinatorRoot, "exchange");

    internal string LogRoot => Path.Combine(CoordinatorRoot, "logs");

    internal string StageArtifactRoot => Path.Combine(OutputRoot, "stage-artifacts");

    internal string ReplayRoot => Path.Combine(OutputRoot, "replay-root");

    internal string QualificationRoot => Path.Combine(OutputRoot, "qualification");

    internal static CoordinatorRequest Load(string path)
    {
        const string label = "shadow run coordinator request";
        var root = StrictJson.ReadObjectFile(path, label);
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
            "slot");

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
        SlotAuthorization? slot = null;
        if (root.TryGetProperty("slot", out var slotNode))
        {
            slot = SlotAuthorization.Read(slotNode, label + " slot");
        }

        var bytes = File.ReadAllBytes(path);
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
            PlannedRunCount = StrictJson.RequireInt(qualification, "plannedRunCount", label + " qualification", 2, 16),
            RunSetKeyPath = StrictJson.RequireString(qualification, "runSetKeyPath", label + " qualification"),
            RequestSha256 = CanonicalJson.Sha256Hex(bytes),
            Slot = slot
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
    /// The slot authorization this run holds, or a refusal naming why it holds
    /// none. Every slot transition asks for it this way, so there is exactly one
    /// place where "no authorization" becomes a refusal.
    /// </summary>
    internal SlotAuthorization RequireSlotAuthorization()
    {
        if (Slot is null)
        {
            throw new ContractException(
                "This request carries no 'slot' section, so it authorizes no launch. " +
                "The PowerShell qualification path remains the default; add an explicit slot section with " +
                "'shadowSlotEnabled': true to select the typed supervisor.");
        }
        if (!Slot.ShadowSlotEnabled)
        {
            throw new ContractException(
                "The request's slot section sets 'shadowSlotEnabled' to false, which is an explicit refusal to " +
                "launch through the typed supervisor. Nothing is launched.");
        }
        return Slot;
    }
}

/// <summary>
/// The authorization for exactly one supervised slot.
/// </summary>
/// <remarks>
/// Everything here is authorization or supervision. There is no model, no
/// prompt, no candidate rule and no verdict rule, and there is no second slot to
/// name: <see cref="CoordinatorRequest.SupervisedSlotName"/> is the only value
/// the name field accepts, so a request cannot ask this build for slot two by
/// writing one down.
///
/// The deadlines are NOT here. They come from the signed qualification plan, so
/// a caller cannot widen a slot's budget by editing its own request; what the
/// request may set is the supervision grace - how long the typed supervisor
/// waits past the plan's own deadline before it concludes the PowerShell owner
/// failed to terminate its own run and kills the tree.
/// </remarks>
internal sealed record SlotAuthorization
{
    internal required bool ShadowSlotEnabled { get; init; }

    internal required string Name { get; init; }

    /// <summary>The agent script the qualification plan names, bound by the plan digest.</summary>
    internal required string ReviewerScriptPath { get; init; }

    /// <summary>The single-use launch-authorization token the declaration minted.</summary>
    internal required string LaunchAuthorizationTokenPath { get; init; }

    internal required int SupervisionGraceSeconds { get; init; }

    internal static SlotAuthorization Read(JsonElement node, string label)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "shadowSlotEnabled",
            "name",
            "reviewerScriptPath",
            "launchAuthorizationTokenPath",
            "supervisionGraceSeconds");

        var name = StrictJson.RequireString(node, "name", label);
        if (!string.Equals(name, CoordinatorRequest.SupervisedSlotName, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} names slot '{name}'. This build supervises exactly one slot, '{CoordinatorRequest.SupervisedSlotName}', " +
                "and has no reconciliation to close a set with.");
        }
        return new SlotAuthorization
        {
            ShadowSlotEnabled = StrictJson.RequireBool(node, "shadowSlotEnabled", label),
            Name = name,
            ReviewerScriptPath = StrictJson.RequireString(node, "reviewerScriptPath", label),
            LaunchAuthorizationTokenPath = StrictJson.RequireString(node, "launchAuthorizationTokenPath", label),
            // A grace of zero would mean the supervisor kills at the same instant
            // the plan's own deadline fires, and the race decides whether the
            // immutable terminal artifact gets written at all. The floor makes the
            // PowerShell owner the writer of its own terminal in every ordering.
            SupervisionGraceSeconds = StrictJson.RequireInt(node, "supervisionGraceSeconds", label, 30, 3600)
        };
    }

    internal MapNode Describe() => new MapNode()
        .Set("name", Name)
        .Set("reviewerScriptPath", ReviewerScriptPath)
        .Set("supervisionGraceSeconds", SupervisionGraceSeconds);
}
