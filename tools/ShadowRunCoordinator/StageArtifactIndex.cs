using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>One boundary as the published contract table declares it.</summary>
internal sealed record StageBoundary(
    string Stage,
    string Kind,
    int ContractVersion,
    IReadOnlyList<string> RequiredFields,
    IReadOnlyList<string> CollectionFields,
    IReadOnlyList<string> MapFields);

/// <summary>
/// The coordinator's read side of the stage file contract.
/// </summary>
/// <remarks>
/// The shape is not written down here. It is read from
/// src/Agents/reviewer/schemas/reviewer.stage-producer-contracts.v1.json, which
/// is pinned against the running producer table, and the envelope it validates is
/// the one described by
/// src/Agents/reviewer/schemas/reviewer.stage-envelope.v1.json. A coordinator that
/// re-derived these by hand would drift from the producers the first time a
/// boundary changed, and the drift would be invisible until a run failed.
///
/// What this class does that the PowerShell reader already does is not
/// duplication for its own sake: it is the typed boundary. The artifacts are read
/// back a second time, in a different runtime with a different deserializer, and
/// the shapes that collapse in PowerShell - a one-element array arriving as a
/// scalar, an empty one arriving as null - are refused here by name rather than
/// silently accepted into a typed field.
/// </remarks>
internal sealed class StageArtifactIndex
{
    private const string ProducerContractSchemaName = "reviewer.stage-producer-contracts.v1.json";
    private const string EnvelopeSchemaName = "reviewer.stage-envelope.v1.json";
    private const int EnvelopeVersion = 1;

    private readonly IReadOnlyList<StageBoundary> _boundaries;

    private StageArtifactIndex(IReadOnlyList<StageBoundary> boundaries)
    {
        _boundaries = boundaries;
    }

    internal IReadOnlyList<StageBoundary> Boundaries => _boundaries;

    internal static string ProducerContractSchemaPath(string toolkitRoot) =>
        Path.Combine(toolkitRoot, "src", "Agents", "reviewer", "schemas", ProducerContractSchemaName);

    internal static string EnvelopeSchemaPath(string toolkitRoot) =>
        Path.Combine(toolkitRoot, "src", "Agents", "reviewer", "schemas", EnvelopeSchemaName);

    internal static StageArtifactIndex FromSchema(string toolkitRoot)
    {
        var path = ProducerContractSchemaPath(toolkitRoot);
        var label = "stage producer contract schema";
        var root = StrictJson.ReadObjectFile(path, label);
        StrictJson.RequireLiteral(root, "kind", "reviewer-stage-producer-contracts", label);
        if (StrictJson.RequireInt(root, "schemaVersion", label, 1, 1000) != 1)
        {
            throw new ContractException($"The {label} at '{path}' is not schema version 1.");
        }

        var rows = StrictJson.RequireArray(root, "boundaries", label);
        var boundaries = new List<StageBoundary>();
        foreach (var row in rows)
        {
            if (row.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {label} holds a {StrictJson.Describe(row.ValueKind)} where a boundary was declared.");
            }
            boundaries.Add(new StageBoundary(
                StrictJson.RequireString(row, "stage", label),
                StrictJson.RequireString(row, "kind", label),
                StrictJson.RequireInt(row, "contractVersion", label, 1, 1000),
                StrictJson.RequireStringArray(row, "requiredFields", label),
                StrictJson.RequireStringArray(row, "collectionFields", label),
                StrictJson.RequireStringArray(row, "mapFields", label)));
        }
        if (boundaries.Count == 0)
        {
            throw new ContractException($"The {label} at '{path}' declares no boundaries.");
        }
        var kinds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var boundary in boundaries)
        {
            if (!kinds.Add(boundary.Kind))
            {
                throw new ContractException($"The {label} declares '{boundary.Kind}' twice.");
            }
        }
        return new StageArtifactIndex(boundaries);
    }

    internal StageBoundary Boundary(string kind)
    {
        foreach (var boundary in _boundaries)
        {
            if (string.Equals(boundary.Kind, kind, StringComparison.Ordinal))
            {
                return boundary;
            }
        }
        throw new ContractException($"'{kind}' is not a boundary the published contract table declares; the schema named {ProducerContractSchemaName} is what this coordinator consumes.");
    }

    /// <summary>
    /// Rereads every artifact under a directory and indexes it, refusing any
    /// envelope or payload that does not match the declared boundary.
    /// </summary>
    internal IReadOnlyList<MapNode> IndexDirectory(string directory, out int rereadCount, out IReadOnlyList<string> stagesSeen)
    {
        if (!Directory.Exists(directory))
        {
            throw new ContractException($"The stage artifact directory '{directory}' does not exist.");
        }
        var files = Directory.GetFiles(directory, "*.stage.json", SearchOption.TopDirectoryOnly)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToList();
        if (files.Count == 0)
        {
            throw new ContractException($"The stage artifact directory '{directory}' holds no '*.stage.json' artifact.");
        }

        var entries = new List<MapNode>();
        var stages = new List<string>();
        foreach (var file in files)
        {
            var entry = ReadArtifact(file, out var stage);
            entries.Add(entry);
            stages.Add(stage);
        }
        rereadCount = files.Count;
        stagesSeen = stages;
        return entries;
    }

    private MapNode ReadArtifact(string path, out string stage)
    {
        var label = $"stage artifact '{Path.GetFileName(path)}'";
        var root = StrictJson.ReadObjectFile(path, label);
        // The envelope is closed in reviewer.stage-envelope.v1.json, so an extra
        // top-level field is a refusal here too. A consumer that tolerated one
        // would disagree with the producer that refuses it.
        StrictJson.RequireNoUnknownFields(root, label, "envelopeVersion", "kind", "contractVersion", "form", "depth", "payload");

        var envelopeVersion = StrictJson.RequireInt(root, "envelopeVersion", label, 1, 1000);
        if (envelopeVersion != EnvelopeVersion)
        {
            throw new ContractException($"The {label} declares envelope version {envelopeVersion.ToString(CultureInfo.InvariantCulture)}; this coordinator reads version {EnvelopeVersion.ToString(CultureInfo.InvariantCulture)} as described by {EnvelopeSchemaName}.");
        }

        var kind = StrictJson.RequireString(root, "kind", label);
        var boundary = Boundary(kind);
        var contractVersion = StrictJson.RequireInt(root, "contractVersion", label, 1, 1000);
        if (contractVersion != boundary.ContractVersion)
        {
            throw new ContractException($"The {label} declares contract version {contractVersion.ToString(CultureInfo.InvariantCulture)} and the published table declares {boundary.ContractVersion.ToString(CultureInfo.InvariantCulture)}.");
        }

        var form = StrictJson.RequireString(root, "form", label);
        if (form is not ("compact" or "indented"))
        {
            throw new ContractException($"The {label} declares unsupported form '{form}'.");
        }
        var depth = StrictJson.RequireInt(root, "depth", label, 2, 64);
        var payload = StrictJson.RequireObject(root, "payload", label);

        var declared = new HashSet<string>(boundary.RequiredFields, StringComparer.Ordinal);
        foreach (var property in payload.EnumerateObject())
        {
            if (!declared.Contains(property.Name))
            {
                throw new ContractException($"The {label} payload carries unknown field '{property.Name}'.");
            }
        }
        foreach (var required in boundary.RequiredFields)
        {
            if (!payload.TryGetProperty(required, out _))
            {
                throw new ContractException($"The {label} payload is missing required field '{required}'.");
            }
        }

        // Zero, one and many all have to arrive as arrays. This is the exact
        // collapse the file contract exists to prevent, and it is checked again
        // on this side because the collapse can also be introduced by whatever
        // wrote the file, not only by the producer that judged the payload.
        var counts = new MapNode();
        foreach (var field in boundary.CollectionFields)
        {
            var items = StrictJson.RequireArray(payload, field, label + " payload");
            counts.Set(field, items.Count);
        }
        foreach (var field in boundary.MapFields)
        {
            if (!payload.TryGetProperty(field, out var value))
            {
                throw new ContractException($"The {label} payload is missing declared map field '{field}'.");
            }
            if (value.ValueKind != JsonValueKind.Object)
            {
                // A map has keys and an array has none, so there is no repair
                // that would not fabricate one.
                throw new ContractException($"The {label} payload map field '{field}' is a {StrictJson.Describe(value.ValueKind)}, not a keyed object.");
            }
            var keys = 0;
            foreach (var _ in value.EnumerateObject())
            {
                keys++;
            }
            counts.Set(field, keys);
        }

        stage = boundary.Stage;
        var bytes = new FileInfo(path).Length;
        return new MapNode()
            .Set("name", Path.GetFileName(path))
            .Set("stage", boundary.Stage)
            .Set("kind", kind)
            .Set("contractVersion", contractVersion)
            .Set("envelopeVersion", envelopeVersion)
            .Set("form", form)
            .Set("depth", depth)
            .Set("byteLength", bytes)
            .Set("sha256", CanonicalJson.Sha256HexOfFile(path))
            .Set("observedCounts", counts);
    }

    /// <summary>
    /// Reads one index entry back out of a persisted coordinator record. State is
    /// reread as strictly as anything else: a resumed run must not inherit an
    /// artifact census that was edited underneath it.
    /// </summary>
    internal static MapNode RereadIndexEntry(JsonElement entry)
    {
        const string label = "coordinator state artifact entry";
        StrictJson.RequireNoUnknownFields(
            entry,
            label,
            "name",
            "stage",
            "kind",
            "contractVersion",
            "envelopeVersion",
            "form",
            "depth",
            "byteLength",
            "sha256",
            "observedCounts");
        var counts = StrictJson.RequireObject(entry, "observedCounts", label);
        var rebuiltCounts = new MapNode();
        foreach (var property in counts.EnumerateObject())
        {
            if (property.Value.ValueKind != JsonValueKind.Number || !property.Value.TryGetInt64(out var count))
            {
                throw new ContractException($"The {label} count '{property.Name}' is not an integer.");
            }
            rebuiltCounts.Set(property.Name, count);
        }
        return new MapNode()
            .Set("name", StrictJson.RequireString(entry, "name", label))
            .Set("stage", StrictJson.RequireString(entry, "stage", label))
            .Set("kind", StrictJson.RequireString(entry, "kind", label))
            .Set("contractVersion", StrictJson.RequireInt(entry, "contractVersion", label, 1, 1000))
            .Set("envelopeVersion", StrictJson.RequireInt(entry, "envelopeVersion", label, 1, 1000))
            .Set("form", StrictJson.RequireString(entry, "form", label))
            .Set("depth", StrictJson.RequireInt(entry, "depth", label, 2, 64))
            .Set("byteLength", StrictJson.RequireInt(entry, "byteLength", label, 0, int.MaxValue))
            .Set("sha256", StrictJson.RequireHex(entry, "sha256", label, 64))
            .Set("observedCounts", rebuiltCounts);
    }
}
