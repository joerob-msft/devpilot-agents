using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// What one declared corpus payload IS, rather than what it happens to contain.
/// </summary>
/// <remarks>
/// The role is declared by the caller and checked for cardinality here, because
/// a corpus that cannot say which of its files is the identity witness has no
/// witness - it has a file called identity.json that anything could have
/// written. Nothing downstream reads a payload differently because of its role;
/// the role exists so that a staging request which omits a whole class of
/// evidence is refused by name instead of producing a smaller corpus that still
/// looks well formed.
/// </remarks>
internal enum CorpusPayloadRole
{
    IdentityWitness,
    CaptureSourceTransport,
    AuthoritativeChange,
    SpanEvidence,
    ChangedFilePayload,
    Config,
    Rule,
    Resource,
    Evidence
}

/// <summary>How a payload's bytes are constrained. Text is checked; binary is preserved.</summary>
internal enum CorpusPayloadForm
{
    /// <summary>Strict UTF-8 with no byte order mark, which is the textual stage file contract.</summary>
    Utf8Text,

    /// <summary>Opaque bytes. Copied exactly and never decoded, so nothing can normalise them.</summary>
    Binary
}

/// <summary>One immutable source file, and the canonical corpus path it will be staged under.</summary>
internal sealed record CorpusPayloadDeclaration
{
    internal required string Path { get; init; }

    internal required string SourcePath { get; init; }

    internal required string Sha256 { get; init; }

    internal required int Length { get; init; }

    internal required CorpusPayloadForm Form { get; init; }

    internal required CorpusPayloadRole Role { get; init; }

    internal MapNode Describe() => new MapNode()
        .Set("path", Path)
        .Set("sha256", Sha256)
        .Set("length", Length)
        .Set("form", CorpusStageRequest.FormName(Form))
        .Set("role", CorpusStageRequest.RoleName(Role));
}

/// <summary>The identity the staged corpus witnesses, field by field.</summary>
internal sealed record CorpusIdentityWitness
{
    internal required string Repository { get; init; }

    internal required int PullRequestId { get; init; }

    internal required int IterationId { get; init; }

    internal required string SourceCommit { get; init; }

    internal required string CommonCommit { get; init; }

    internal required string TargetCommit { get; init; }

    internal required string Status { get; init; }

    internal required bool IsDraft { get; init; }

    /// <summary>The corpus-relative path the witness is staged at, and the first file written.</summary>
    internal required string WitnessPath { get; init; }

    /// <summary>
    /// The witness as the corpus index records it, under the pull request
    /// identifier the subject names.
    /// </summary>
    internal MapNode DescribeForIndex() => new MapNode()
        .Set("pullRequestId", PullRequestId)
        .Set("iteration", IterationId)
        .Set("source", SourceCommit)
        .Set("common", CommonCommit)
        .Set("target", TargetCommit)
        .Set("status", Status)
        .Set("isDraft", IsDraft);
}

/// <summary>
/// The versioned declaration that one corpus is to be built, from named
/// immutable inputs, into a directory that does not yet exist.
/// </summary>
/// <remarks>
/// This contract exists because the preparation it replaces was a private script
/// that copied a read-only corpus and then tried to rewrite the identity witness
/// inside the copy. The copy inherited the source's read-only attributes, the
/// rewrite was denied, and the failure landed before the coordinator could
/// account for it. The lesson is written into the shape here: an input is a
/// SOURCE and is only ever read, an output is built from nothing at a path that
/// must not already exist, and the witness is written first rather than patched
/// afterwards.
///
/// Everything identifying is declared, including the digest and byte length of
/// every payload and the digest the finished index must have. Nothing is
/// discovered by walking a directory, because a corpus assembled from whatever
/// happened to be on disk is a corpus nobody declared.
/// </remarks>
internal sealed record CorpusStageRequest
{
    internal const string ContractVersionValue = "devpilot.shadow-run-coordinator.corpus-stage-request.v1";
    internal const string KindValue = "shadow-run-corpus-stage";

    /// <summary>The generated index's name, which is therefore not a name a payload may claim.</summary>
    internal const string IndexFileName = "corpus-index.json";

    /// <summary>The largest corpus this stager will assemble, matching the sealer's own ceiling.</summary>
    private const int MaximumPayloads = 4096;

    /// <summary>The largest single payload, matching the sealer's own ceiling.</summary>
    private const int MaximumPayloadBytes = 25165824;

    internal required string ContractVersion { get; init; }

    internal required string Kind { get; init; }

    internal required string CorrelationId { get; init; }

    internal required string ToolkitHead { get; init; }

    internal required string OutputRoot { get; init; }

    /// <summary>Where the finished corpus is published. It must not exist when staging begins.</summary>
    internal required string CorpusRoot { get; init; }

    /// <summary>The digest the generated index must have, declared before anything is built.</summary>
    internal required string IndexSha256 { get; init; }

    internal required string CorpusKind { get; init; }

    internal required CorpusIdentityWitness Identity { get; init; }

    internal required IReadOnlyList<CorpusPayloadDeclaration> Payloads { get; init; }

    /// <summary>The digest of the exact declaration bytes, so a resume cannot stage a different one.</summary>
    internal required string RequestSha256 { get; init; }

    internal static string RoleName(CorpusPayloadRole role) => role switch
    {
        CorpusPayloadRole.IdentityWitness => "identityWitness",
        CorpusPayloadRole.CaptureSourceTransport => "captureSourceTransport",
        CorpusPayloadRole.AuthoritativeChange => "authoritativeChange",
        CorpusPayloadRole.SpanEvidence => "spanEvidence",
        CorpusPayloadRole.ChangedFilePayload => "changedFilePayload",
        CorpusPayloadRole.Config => "config",
        CorpusPayloadRole.Rule => "rule",
        CorpusPayloadRole.Resource => "resource",
        CorpusPayloadRole.Evidence => "evidence",
        _ => throw new ContractException("An unnamed corpus payload role cannot be recorded.")
    };

    internal static string FormName(CorpusPayloadForm form) => form switch
    {
        CorpusPayloadForm.Utf8Text => "utf8Text",
        CorpusPayloadForm.Binary => "binary",
        _ => throw new ContractException("An unnamed corpus payload form cannot be recorded.")
    };

    private static CorpusPayloadRole ParseRole(string text, string label) => text switch
    {
        "identityWitness" => CorpusPayloadRole.IdentityWitness,
        "captureSourceTransport" => CorpusPayloadRole.CaptureSourceTransport,
        "authoritativeChange" => CorpusPayloadRole.AuthoritativeChange,
        "spanEvidence" => CorpusPayloadRole.SpanEvidence,
        "changedFilePayload" => CorpusPayloadRole.ChangedFilePayload,
        "config" => CorpusPayloadRole.Config,
        "rule" => CorpusPayloadRole.Rule,
        "resource" => CorpusPayloadRole.Resource,
        "evidence" => CorpusPayloadRole.Evidence,
        _ => throw new ContractException($"The {label} declares role '{text}', which is not a role this stager stages.")
    };

    private static CorpusPayloadForm ParseForm(string text, string label) => text switch
    {
        "utf8Text" => CorpusPayloadForm.Utf8Text,
        "binary" => CorpusPayloadForm.Binary,
        _ => throw new ContractException($"The {label} declares form '{text}', which is not a form this stager stages.")
    };

    /// <summary>
    /// The roles a corpus is not allowed to be missing.
    /// </summary>
    /// <remarks>
    /// A staging request that simply omitted the authoritative change set, or the
    /// span evidence, or the capture artifact would build a corpus that is
    /// internally consistent and downstream useless, and the omission would only
    /// be noticed by whatever failed to find the file much later. Declared here so
    /// it is refused at the door, by name.
    /// </remarks>
    private static readonly CorpusPayloadRole[] MandatoryRoles =
    [
        CorpusPayloadRole.IdentityWitness,
        CorpusPayloadRole.CaptureSourceTransport,
        CorpusPayloadRole.AuthoritativeChange,
        CorpusPayloadRole.SpanEvidence,
        CorpusPayloadRole.ChangedFilePayload,
        CorpusPayloadRole.Config,
        CorpusPayloadRole.Rule,
        CorpusPayloadRole.Resource
    ];

    /// <summary>
    /// Reads the declaration this run will obey, from the one set of bytes whose
    /// digest is checked against <paramref name="boundSha256"/>.
    /// </summary>
    /// <remarks>
    /// The bytes are read exactly once. Hashing the file and then parsing the
    /// file are two reads of a path that another process may own, and between
    /// them a declaration can change its payload forms, roles or source paths
    /// while still satisfying a digest taken before the change and an index
    /// digest taken after it. The window is closed by never having one: the
    /// caller's bound digest is checked against this buffer, and this buffer is
    /// what is parsed and what <see cref="RequestSha256"/> reports.
    /// </remarks>
    internal static CorpusStageRequest Load(string path, string boundSha256)
    {
        const string label = "corpus stage request";
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ContractException($"The {label} path is empty.");
        }
        if (!File.Exists(path))
        {
            throw new ContractException($"The {label} at '{path}' does not exist.");
        }
        var bytes = File.ReadAllBytes(path);
        var requestSha256 = CanonicalJson.Sha256Hex(bytes);
        if (!string.IsNullOrEmpty(boundSha256) && !string.Equals(requestSha256, boundSha256, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} at '{path}' digests to {requestSha256}, and the request binds {boundSha256}.");
        }
        var root = StrictJson.ReadObjectBytes(bytes, path, label);
        StrictJson.RequireNoUnknownFields(
            root,
            label,
            "contractVersion",
            "kind",
            "correlationId",
            "toolkitHead",
            "target",
            "corpusKind",
            "identity",
            "payloads");

        var contractVersion = StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, label);
        var kind = StrictJson.RequireLiteral(root, "kind", KindValue, label);

        var target = StrictJson.RequireObject(root, "target", label);
        StrictJson.RequireNoUnknownFields(target, label + " target", "outputRoot", "corpusRoot", "indexSha256");

        var identityNode = StrictJson.RequireObject(root, "identity", label);
        StrictJson.RequireNoUnknownFields(
            identityNode,
            label + " identity",
            "repository",
            "pullRequestId",
            "iterationId",
            "sourceCommit",
            "commonCommit",
            "targetCommit",
            "status",
            "isDraft",
            "witnessPath");

        var identity = new CorpusIdentityWitness
        {
            Repository = RequireRepository(identityNode, label + " identity"),
            PullRequestId = StrictJson.RequireInt(identityNode, "pullRequestId", label + " identity", 1, int.MaxValue),
            IterationId = StrictJson.RequireInt(identityNode, "iterationId", label + " identity", 1, 4096),
            SourceCommit = StrictJson.RequireHex(identityNode, "sourceCommit", label + " identity", 40),
            CommonCommit = StrictJson.RequireHex(identityNode, "commonCommit", label + " identity", 40),
            TargetCommit = StrictJson.RequireHex(identityNode, "targetCommit", label + " identity", 40),
            Status = RequireStatus(identityNode, label + " identity"),
            IsDraft = StrictJson.RequireBool(identityNode, "isDraft", label + " identity"),
            WitnessPath = StrictJson.RequireString(identityNode, "witnessPath", label + " identity")
        };

        var declared = StrictJson.RequireArray(root, "payloads", label);
        if (declared.Count is < 1 or > MaximumPayloads)
        {
            throw new ContractException(
                $"The {label} declares {declared.Count.ToString(CultureInfo.InvariantCulture)} payload(s); this stager stages 1 to {MaximumPayloads.ToString(CultureInfo.InvariantCulture)}.");
        }

        var payloads = new List<CorpusPayloadDeclaration>(declared.Count);
        var folded = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var exact = new HashSet<string>(StringComparer.Ordinal);
        var sourcesFolded = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var previousPath = string.Empty;
        for (var index = 0; index < declared.Count; index++)
        {
            var payloadLabel = $"{label} payload {index.ToString(CultureInfo.InvariantCulture)}";
            var node = declared[index];
            if (node.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {payloadLabel} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
            }
            StrictJson.RequireNoUnknownFields(node, payloadLabel, "path", "sourcePath", "sha256", "length", "form", "role");

            var relative = StrictJson.RequireString(node, "path", payloadLabel);
            RequireCanonicalRelativePath(relative, payloadLabel);
            if (string.Equals(relative, IndexFileName, StringComparison.OrdinalIgnoreCase))
            {
                throw new ContractException(
                    $"The {payloadLabel} declares '{relative}', which this stager generates from the declaration itself. " +
                    "A corpus whose index is copied in rather than derived is an index nothing verified.");
            }
            if (!exact.Add(relative))
            {
                throw new ContractException($"The {label} declares '{relative}' more than once.");
            }
            if (folded.TryGetValue(relative, out var alias))
            {
                throw new ContractException(
                    $"The {label} declares '{relative}' and '{alias}', which name one file on a case-insensitive filesystem.");
            }
            folded[relative] = relative;
            // Ordered ordinally by the declaration itself, because the generated
            // index lists payloads in declaration order and a canonical index
            // cannot depend on the order a caller happened to write them in.
            if (previousPath.Length > 0 && string.CompareOrdinal(previousPath, relative) >= 0)
            {
                throw new ContractException(
                    $"The {label} declares '{relative}' after '{previousPath}'; payloads are declared in ascending ordinal path order so the generated index is canonical.");
            }
            previousPath = relative;

            var sourcePath = StrictJson.RequireString(node, "sourcePath", payloadLabel);
            var fullSource = FullSourcePath(sourcePath, payloadLabel);
            if (sourcesFolded.TryGetValue(fullSource, out var sourceAlias))
            {
                throw new ContractException(
                    $"The {label} reads '{fullSource}' for both '{relative}' and '{sourceAlias}'; one source file may not be staged twice under two names.");
            }
            sourcesFolded[fullSource] = relative;

            payloads.Add(new CorpusPayloadDeclaration
            {
                Path = relative,
                SourcePath = fullSource,
                Sha256 = StrictJson.RequireHex(node, "sha256", payloadLabel, 64),
                Length = StrictJson.RequireInt(node, "length", payloadLabel, 0, MaximumPayloadBytes),
                Form = ParseForm(StrictJson.RequireString(node, "form", payloadLabel), payloadLabel),
                Role = ParseRole(StrictJson.RequireString(node, "role", payloadLabel), payloadLabel)
            });
        }

        RequireRoleCardinality(payloads, identity, label);

        return new CorpusStageRequest
        {
            ContractVersion = contractVersion,
            Kind = kind,
            CorrelationId = StrictJson.RequireString(root, "correlationId", label),
            ToolkitHead = StrictJson.RequireHex(root, "toolkitHead", label, 40),
            OutputRoot = StrictJson.RequireString(target, "outputRoot", label + " target"),
            CorpusRoot = StrictJson.RequireString(target, "corpusRoot", label + " target"),
            IndexSha256 = StrictJson.RequireHex(target, "indexSha256", label + " target", 64),
            CorpusKind = RequireCorpusKind(root, label),
            Identity = identity,
            Payloads = payloads,
            RequestSha256 = requestSha256
        };
    }

    /// <summary>
    /// The one corpus shape this stager builds.
    /// </summary>
    /// <remarks>
    /// Named as a literal rather than accepted from the caller, because the
    /// promotable and non-promotable kinds are not two spellings of one thing:
    /// the immutable non-promotable kind is the only one whose contents may never
    /// leave the private root, and a stager that let a request choose would let a
    /// request relabel private evidence on its way out.
    /// </remarks>
    private static string RequireCorpusKind(JsonElement root, string label) =>
        StrictJson.RequireLiteral(root, "corpusKind", "private-immutable-non-promotable-research-corpus", label);

    private static string RequireRepository(JsonElement parent, string label)
    {
        var text = StrictJson.RequireString(parent, "repository", label);
        var parts = text.Split('/');
        if (parts.Length != 3)
        {
            throw new ContractException($"The {label} field 'repository' is '{text}'; the corpus names its origin as 'organization/project/repository'.");
        }
        foreach (var part in parts)
        {
            if (part.Length is 0 or > 128 || part.Any(char.IsWhiteSpace))
            {
                throw new ContractException($"The {label} field 'repository' is '{text}'; each of its three parts is 1 to 128 characters and carries no whitespace.");
            }
        }
        return text;
    }

    private static string RequireStatus(JsonElement parent, string label)
    {
        var text = StrictJson.RequireString(parent, "status", label);
        if (text.Length > 24 || !text.All(character => character is >= 'a' and <= 'z'))
        {
            throw new ContractException($"The {label} field 'status' is '{text}'; a witnessed status is 1 to 24 lower-case letters.");
        }
        return text;
    }

    /// <summary>
    /// The absolute source path, refused unless it is already absolute and free
    /// of the relative segments a later join would resolve somewhere else.
    /// </summary>
    private static string FullSourcePath(string sourcePath, string label)
    {
        if (!System.IO.Path.IsPathFullyQualified(sourcePath))
        {
            throw new ContractException($"The {label} field 'sourcePath' is '{sourcePath}', which is not a fully qualified path.");
        }
        foreach (var segment in sourcePath.Split('/', '\\'))
        {
            if (segment is "." or "..")
            {
                throw new ContractException($"The {label} field 'sourcePath' walks through '{segment}'; a source is named outright rather than navigated to.");
            }
        }
        return System.IO.Path.GetFullPath(sourcePath);
    }

    /// <summary>
    /// One shape of corpus-relative path, and only one.
    /// </summary>
    /// <remarks>
    /// Deliberately the same rule the PowerShell corpus reader enforces in
    /// src/Agents/reviewer/CorpusSeal.ps1, because a path this stager writes and
    /// that reader refuses would produce a corpus the sealer cannot open. A
    /// backslash, a colon, a '.' or '..' segment, a doubled or leading or
    /// trailing slash and a drive letter are all ALIASES for some other path, and
    /// an alias is exactly how a file lands outside the corpus it was declared
    /// inside.
    /// </remarks>
    internal static void RequireCanonicalRelativePath(string relative, string label)
    {
        if (relative.Length > 512)
        {
            throw new ContractException($"The {label} path '{relative}' is longer than 512 characters.");
        }
        if (relative.Contains('\\', StringComparison.Ordinal) || relative.Contains(':', StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} path '{relative}' carries a backslash or a colon; a corpus path uses '/' and names no volume or stream.");
        }
        if (relative.StartsWith('/') || relative.EndsWith('/') || relative.Contains("//", StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} path '{relative}' is not a plain relative path.");
        }
        foreach (var segment in relative.Split('/'))
        {
            if (segment.Length is 0 or > 127)
            {
                throw new ContractException($"The {label} path '{relative}' holds a segment of {segment.Length.ToString(CultureInfo.InvariantCulture)} characters; each is 1 to 127.");
            }
            var head = segment[0];
            if (!(head is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9')))
            {
                throw new ContractException($"The {label} path '{relative}' holds segment '{segment}', which does not begin with a letter or a digit.");
            }
            foreach (var character in segment)
            {
                var ok = character is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '.' or '_' or '-';
                if (!ok)
                {
                    throw new ContractException($"The {label} path '{relative}' holds segment '{segment}', which carries a character outside [A-Za-z0-9._-].");
                }
            }
        }
    }

    private static void RequireRoleCardinality(
        IReadOnlyList<CorpusPayloadDeclaration> payloads,
        CorpusIdentityWitness identity,
        string label)
    {
        var witnesses = payloads.Where(payload => payload.Role == CorpusPayloadRole.IdentityWitness).ToList();
        if (witnesses.Count != 1)
        {
            throw new ContractException(
                $"The {label} declares {witnesses.Count.ToString(CultureInfo.InvariantCulture)} identity witness payload(s); a corpus witnesses its subject exactly once.");
        }
        if (!string.Equals(witnesses[0].Path, identity.WitnessPath, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} names '{identity.WitnessPath}' as its identity witness and gives the witness role to '{witnesses[0].Path}'.");
        }
        if (witnesses[0].Form != CorpusPayloadForm.Utf8Text)
        {
            throw new ContractException($"The {label} declares its identity witness as binary; a witness is read, so it is textual.");
        }
        foreach (var role in MandatoryRoles)
        {
            if (!payloads.Any(payload => payload.Role == role))
            {
                throw new ContractException(
                    $"The {label} declares no payload in the '{RoleName(role)}' role; a corpus staged without one is missing evidence nothing downstream would ask for by name.");
            }
        }
    }

    /// <summary>
    /// The corpus index this declaration produces, built from the declaration and
    /// never from a directory walk.
    /// </summary>
    /// <remarks>
    /// Rendered through the coordinator's canonical form, which is the same
    /// sorted-key, whitespace-free rendering the toolkit's PowerShell
    /// canonicalizer produces. That is what lets the caller declare the finished
    /// index's digest BEFORE anything is built, and lets the PowerShell side
    /// remain the normative statement of what the bytes are while this
    /// implementation merely has to agree with it.
    /// </remarks>
    internal string RenderIndex()
    {
        var identities = new MapNode()
            .Set(Identity.PullRequestId.ToString(CultureInfo.InvariantCulture), Identity.DescribeForIndex());
        var list = new ListNode();
        foreach (var payload in Payloads)
        {
            list.Add(new MapNode()
                .Set("path", payload.Path)
                .Set("sha256", payload.Sha256)
                .Set("length", payload.Length));
        }
        var index = new MapNode()
            .Set("kind", CorpusKind)
            .Set("repository", Identity.Repository)
            .Set("payloadCount", Payloads.Count)
            .Set("identities", identities)
            .Set("payloads", list);
        return CanonicalJson.Canonical(index);
    }

    /// <summary>The declaration as the durable record carries it, without any source path.</summary>
    /// <remarks>
    /// Source paths are deliberately absent from the record. They name where the
    /// bytes were read from on one machine at one time; what the corpus is, and
    /// what a later run must be able to check, is the path, digest and length of
    /// each staged payload.
    /// </remarks>
    internal MapNode DescribePayloads()
    {
        var list = new ListNode();
        foreach (var payload in Payloads)
        {
            list.Add(payload.Describe());
        }
        return new MapNode().Set("payloadCount", Payloads.Count).Set("payloads", list);
    }
}
