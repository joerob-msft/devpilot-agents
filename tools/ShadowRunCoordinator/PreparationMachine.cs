using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Drives one preparation from a validated request to a verified run set that is
/// ready to launch, and stops there.
/// </summary>
/// <remarks>
/// Two invariants shape every method below.
///
/// Idempotence. Each transition asks the durable record whether it has already
/// happened and returns without doing anything if it has. That is what makes a
/// kill at any point safe: a resumed run does not relaunch a child whose evidence
/// is already on disk, and it does not accept a half-written artifact as though
/// the child had finished, because the evidence is only read after the child
/// exited zero and the state is only committed after the evidence was read.
///
/// No decisions. Nothing here selects a model, ranks a candidate, arbitrates a
/// severity or launches a slot. The preparation ends one step short of a launch
/// on purpose: what this class knows how to do is sequence and verify, and the
/// enumeration it walks has no state after runSetReady to walk into.
/// </remarks>
internal sealed class PreparationMachine(
    CoordinatorRequest request,
    CoordinatorState state,
    byte[] stateKey,
    StageArtifactIndex index,
    ChildToolInvoker invoker,
    TextWriter log)
{
    private const string ChildScriptName = "Invoke-ShadowCoordinatorChild.ps1";

    private readonly CoordinatorRequest _request = request;
    private readonly CoordinatorState _state = state;
    private readonly byte[] _stateKey = stateKey;
    private readonly StageArtifactIndex _index = index;
    private readonly ChildToolInvoker _invoker = invoker;
    private readonly TextWriter _log = log;

    private string _sealedSnapshotName = string.Empty;
    private string _sealedManifestPath = string.Empty;
    private string _sealedManifestDigest = string.Empty;
    private string _sealedSnapshotDigest = string.Empty;
    private string _runSetPath = string.Empty;

    /// <summary>Runs until the target state is reached, halting early only when instructed to.</summary>
    internal void Run(PreparationState target, PreparationState? haltAfter)
    {
        foreach (var next in PreparationStateNames.Ordered)
        {
            if (next > target)
            {
                break;
            }
            Advance(next);
            if (haltAfter == next)
            {
                _log.WriteLine($"halt-after {PreparationStateNames.ToName(next)} (correlationId={_request.CorrelationId}, sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)})");
                throw new DeliberateHaltException(next);
            }
        }
        WriteAudit();
    }

    private void Advance(PreparationState next)
    {
        if (_state.State >= next)
        {
            _log.WriteLine($"skip {PreparationStateNames.ToName(next)} (already recorded at sequence {SequenceOf(next)}, correlationId={_request.CorrelationId})");
            RehydrateFor(next);
            return;
        }
        _log.WriteLine($"enter {PreparationStateNames.ToName(next)} (correlationId={_request.CorrelationId})");
        var (evidence, detail) = next switch
        {
            PreparationState.RequestValidated => ValidateRequest(),
            PreparationState.CorpusValidated => ValidateCorpus(),
            PreparationState.RecipePlanned => PlanRecipe(),
            PreparationState.SnapshotValidateOnly => ValidateSnapshotOnly(),
            PreparationState.SnapshotSealed => SealSnapshot(),
            PreparationState.SnapshotVerified => VerifySnapshot(),
            PreparationState.RunSetDeclared => DeclareRunSet(),
            PreparationState.RunSetVerified => VerifyRunSet(),
            PreparationState.RunSetReady => ConfirmRunSetReady(),
            _ => throw new ContractException($"'{PreparationStateNames.ToName(next)}' is not a transition this coordinator performs.")
        };
        _state.Commit(_request, _stateKey, next, evidence, detail);
        _log.WriteLine($"commit {PreparationStateNames.ToName(next)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} evidence={_state.EvidenceDigestOf(next)} detail={detail}");
    }

    private string SequenceOf(PreparationState state)
    {
        foreach (var transition in _state.Transitions)
        {
            if (transition.State == state)
            {
                return transition.Sequence.ToString(CultureInfo.InvariantCulture);
            }
        }
        return "unknown";
    }

    /// <summary>
    /// Recovers the in-memory values a later transition needs when an earlier one
    /// is being skipped after a restart.
    /// </summary>
    /// <remarks>
    /// The values are re-read from the files on disk, so a resumed run reads the
    /// same evidence a fresh one would - but every file is first checked against
    /// the digest the signed state committed for it. The exchange directory holds
    /// no signature of its own, so without that check a resumed run could bind to
    /// a snapshot or run set other than the one its own record was committed
    /// against, and every downstream check would be self-consistent and pass.
    /// </remarks>
    private void RehydrateFor(PreparationState state)
    {
        switch (state)
        {
            case PreparationState.SnapshotSealed:
                ReadSealResult();
                break;
            case PreparationState.RecipePlanned:
                RecheckRecordedArtifacts();
                break;
            case PreparationState.RunSetDeclared:
                ReadDeclareResult();
                break;
        }
    }

    /// <summary>
    /// Rehashes every stage artifact the recipePlanned transition committed.
    /// </summary>
    /// <remarks>
    /// A resumed run inherits the artifact census from its signed record rather
    /// than reindexing a directory, but inheriting a census is only worth
    /// anything if the files it names are still the files it named. Without this
    /// a run killed after publication could be resumed against artifacts that had
    /// been edited in between, and the audit would still index the digests from
    /// before the edit.
    /// </remarks>
    private void RecheckRecordedArtifacts()
    {
        var evidence = _state.EvidenceFor(PreparationState.RecipePlanned);
        if (evidence is null)
        {
            throw new ContractException("The state record is past recipePlanned but carries no evidence for it, so the resume has no census to prove.");
        }
        if (evidence.Get("artifacts") is not ListNode artifacts)
        {
            // Returning here would make the whole recheck opt-out: a record whose
            // census was removed or replaced with a scalar would resume with
            // nothing verified and nothing said. The shape of committed evidence
            // is not something to assume.
            throw new ContractException("The recipePlanned record carries no stage artifact census, so the resume cannot prove its artifacts are unchanged.");
        }
        var recordedDirectory = evidence.GetText("artifactDirectory");
        if (recordedDirectory is null)
        {
            throw new ContractException("The recipePlanned record carries an artifact census but no directory to resolve it against.");
        }
        var checkedCount = 0;
        foreach (var item in artifacts.Items)
        {
            if (item is not MapNode artifact)
            {
                throw new ContractException("The recipePlanned census holds an entry that is not an artifact record.");
            }
            var name = artifact.GetText("name");
            var recorded = artifact.GetText("sha256");
            if (name is null || recorded is null)
            {
                throw new ContractException("A censused stage artifact carries no name or no digest, so the resume cannot prove it is unchanged.");
            }
            var path = Path.Combine(recordedDirectory, name);
            if (!File.Exists(path))
            {
                throw new ContractException($"The stage artifact '{path}' recorded at recipePlanned is gone; this run cannot be resumed against a censused artifact set it no longer has.");
            }
            var actual = CanonicalJson.Sha256HexOfFile(path);
            if (!string.Equals(actual, recorded, StringComparison.Ordinal))
            {
                throw new ContractException($"The stage artifact '{path}' now digests to {actual} and was committed as {recorded}.");
            }
            checkedCount++;
        }
        if (checkedCount != _index.Boundaries.Count)
        {
            throw new ContractException($"The resume rehashed {checkedCount.ToString(CultureInfo.InvariantCulture)} stage artifact(s) and the record censused {_index.Boundaries.Count.ToString(CultureInfo.InvariantCulture)}.");
        }
        _log.WriteLine($"resume rehashed {checkedCount.ToString(CultureInfo.InvariantCulture)} stage artifact(s) (correlationId={_request.CorrelationId})");
    }

    /// <summary>
    /// Reads a child result file back on resume, refusing it unless it is byte
    /// for byte the file the transition was committed against.
    /// </summary>
    private JsonElement ReadCommittedChildResult(PreparationState state, string step, string label)
    {
        var path = Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + step + ".result.json");
        var committed = _state.EvidenceFor(state)?.GetText("childResultSha256");
        if (committed is null)
        {
            throw new ContractException($"The committed {PreparationStateNames.ToName(state)} evidence records no child result digest to resume against.");
        }
        if (!File.Exists(path))
        {
            throw new ContractException($"The {label} at '{path}' is gone; this run cannot be resumed without the result its record was committed against.");
        }
        var actual = CanonicalJson.Sha256HexOfFile(path);
        if (!string.Equals(actual, committed, StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} at '{path}' now digests to {actual} and the committed record binds {committed}.");
        }
        return StrictJson.ReadObjectFile(path, label);
    }

    // -----------------------------------------------------------------------
    // requestValidated
    // -----------------------------------------------------------------------
    private (MapNode Evidence, string Detail) ValidateRequest()
    {
        if (!Directory.Exists(_request.ToolkitRoot))
        {
            throw new ContractException($"The toolkit root '{_request.ToolkitRoot}' does not exist.");
        }
        var head = GitHead.Resolve(_request.ToolkitRoot);
        if (!string.Equals(head, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The toolkit at '{_request.ToolkitRoot}' is at head {head}, and the request binds {_request.ToolkitHead}.");
        }

        var schemaPath = StageArtifactIndex.ProducerContractSchemaPath(_request.ToolkitRoot);
        RequireDigest(schemaPath, _request.SchemaSha256, "stage producer contract schema");
        RequireDigest(_request.ReviewerConfigPath, _request.ConfigSha256, "reviewer configuration");

        var assets = PromptAssetDigest(_request.ToolkitRoot);
        if (!string.Equals(assets, _request.PromptSha256, StringComparison.Ordinal))
        {
            throw new ContractException($"The reviewer prompt assets digest to {assets}, and the request binds {_request.PromptSha256}.");
        }

        Directory.CreateDirectory(_request.OutputRoot);
        Directory.CreateDirectory(_request.CoordinatorRoot);

        var evidence = new MapNode()
            .Set("toolkitHead", head)
            .Set("schemaSha256", _request.SchemaSha256)
            .Set("configSha256", _request.ConfigSha256)
            .Set("promptAssetsSha256", assets)
            .Set("subject", _request.DescribeSubject())
            .Set("boundaryCount", _index.Boundaries.Count);
        return (evidence, $"head={head} boundaries={_index.Boundaries.Count.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// A digest over the reviewer's prompt assets, computed from their file
    /// digests and never from their content. The coordinator binds the run to the
    /// prompts that would be used without ever reading a prompt into a decision.
    /// </summary>
    private static string PromptAssetDigest(string toolkitRoot)
    {
        var directory = Path.Combine(toolkitRoot, "src", "Agents", "reviewer");
        var files = Directory.GetFiles(directory, "*.prompt.md", SearchOption.TopDirectoryOnly)
            .OrderBy(name => Path.GetFileName(name), StringComparer.Ordinal)
            .ToList();
        if (files.Count == 0)
        {
            throw new ContractException($"'{directory}' holds no reviewer prompt asset to bind the run to.");
        }
        var list = new ListNode();
        foreach (var file in files)
        {
            list.Add(new MapNode()
                .Set("name", Path.GetFileName(file))
                .Set("sha256", CanonicalJson.Sha256HexOfFile(file)));
        }
        return CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(list));
    }

    private static void RequireDigest(string path, string expected, string label)
    {
        if (!File.Exists(path))
        {
            throw new ContractException($"The {label} at '{path}' does not exist.");
        }
        var actual = CanonicalJson.Sha256HexOfFile(path);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} at '{path}' digests to {actual}, and the request binds {expected}.");
        }
    }

    // -----------------------------------------------------------------------
    // corpusValidated
    // -----------------------------------------------------------------------
    private (MapNode Evidence, string Detail) ValidateCorpus()
    {
        if (!Directory.Exists(_request.CorpusRoot))
        {
            throw new ContractException($"The corpus root '{_request.CorpusRoot}' does not exist.");
        }
        var indexPath = Path.Combine(_request.CorpusRoot, "corpus-index.json");
        RequireDigest(indexPath, _request.CorpusIndexSha256, "corpus index");

        const string label = "corpus index";
        var root = StrictJson.ReadObjectFile(indexPath, label);
        var kind = StrictJson.RequireString(root, "kind", label);
        var declaredCount = StrictJson.RequireInt(root, "payloadCount", label, 1, 100000);
        var payloads = StrictJson.RequireArray(root, "payloads", label);
        if (payloads.Count != declaredCount)
        {
            throw new ContractException($"The {label} declares {declaredCount.ToString(CultureInfo.InvariantCulture)} payload(s) and lists {payloads.Count.ToString(CultureInfo.InvariantCulture)}.");
        }
        foreach (var payload in payloads)
        {
            if (payload.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {label} holds a {StrictJson.Describe(payload.ValueKind)} where a payload was declared.");
            }
            StrictJson.RequireString(payload, "path", label + " payload");
            StrictJson.RequireHex(payload, "sha256", label + " payload", 64);
        }

        // The corpus names the repository it came from. Binding it here means a
        // request cannot point a subject at somebody else's evidence.
        var repository = StrictJson.RequireString(root, "repository", label);
        var expected = $"{_request.Organization}/{_request.Project}/{_request.Repository}";
        if (!string.Equals(repository, expected, StringComparison.Ordinal))
        {
            throw new ContractException($"The corpus was captured from '{repository}' and the request names '{expected}'.");
        }

        if (!File.Exists(_request.CorpusRecipePath))
        {
            throw new ContractException($"The corpus recipe '{_request.CorpusRecipePath}' does not exist.");
        }
        var recipeLabel = "corpus seal recipe";
        var recipe = StrictJson.ReadObjectFile(_request.CorpusRecipePath, recipeLabel);
        StrictJson.RequireString(recipe, "kind", recipeLabel);

        var evidence = new MapNode()
            .Set("corpusIndexSha256", _request.CorpusIndexSha256)
            .Set("corpusKind", kind)
            .Set("payloadCount", declaredCount)
            .Set("repository", repository)
            .Set("recipeSha256", CanonicalJson.Sha256HexOfFile(_request.CorpusRecipePath));
        return (evidence, $"payloads={declaredCount.ToString(CultureInfo.InvariantCulture)}");
    }

    // -----------------------------------------------------------------------
    // recipePlanned - where all twelve stage boundaries are published and reread
    // -----------------------------------------------------------------------
    private (MapNode Evidence, string Detail) PlanRecipe()
    {
        var census = ReadDeclaredChangedPaths();
        var childRequest = new MapNode()
            .Set("contractVersion", ChildRequestContractVersion)
            .Set("toolkitRoot", _request.ToolkitRoot)
            .Set("artifactDirectory", _request.StageArtifactRoot)
            .Set("changedPaths", census);

        var outcome = _invoker.Invoke("stagePreparation", ChildScript(), childRequest, "artifactDirectory", "publishedCount");

        var published = StrictJson.RequireInt(outcome.Result, "publishedCount", "'stagePreparation' child result", 1, 4096);
        var reported = StrictJson.RequireString(outcome.Result, "artifactDirectory", "'stagePreparation' child result");

        // The child is told where to publish and does not get to answer with
        // somewhere else. Indexing the directory the child names rather than the
        // one the request declared would let a replaced adapter satisfy every
        // check below with twelve well-formed artifacts written anywhere on the
        // filesystem, and the committed evidence would then record artifacts from
        // outside the declared output root.
        var declaredDirectory = Path.GetFullPath(_request.StageArtifactRoot);
        if (!string.Equals(Path.GetFullPath(reported), declaredDirectory, StringComparison.OrdinalIgnoreCase))
        {
            throw new ContractException($"The stage preparation published into '{reported}' and the request declared '{declaredDirectory}'.");
        }
        var directory = declaredDirectory;

        // The coordinator does not take the child's word for what it published.
        // Every artifact is read back here, through a different runtime and a
        // different deserializer, against the boundary the published contract
        // table declares.
        var entries = _index.IndexDirectory(directory, out var rereadCount, out var stagesSeen);
        if (rereadCount != published)
        {
            throw new ContractException($"The stage preparation reported {published.ToString(CultureInfo.InvariantCulture)} artifact(s) and the directory holds {rereadCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        var distinct = new HashSet<string>(stagesSeen, StringComparer.Ordinal);
        foreach (var boundary in _index.Boundaries)
        {
            if (!distinct.Contains(boundary.Stage))
            {
                throw new ContractException($"The stage preparation never reached the '{boundary.Stage}' boundary.");
            }
        }
        if (distinct.Count != _index.Boundaries.Count)
        {
            throw new ContractException($"The stage preparation reached {distinct.Count.ToString(CultureInfo.InvariantCulture)} of {_index.Boundaries.Count.ToString(CultureInfo.InvariantCulture)} boundaries.");
        }

        // The census of what was reread becomes part of the durable record, so a
        // resumed run inherits the same artifact set rather than reindexing a
        // directory that may have been touched since.
        var indexed = new ListNode();
        foreach (var entry in entries)
        {
            _state.RecordArtifact(entry);
            indexed.Add(entry);
        }

        var evidence = new MapNode()
            .Set("artifactDirectory", directory)
            .Set("changedPathCount", census.Count)
            .Set("changedPathsSha256", CanonicalJson.Sha256HexOfFile(_request.ChangedPathsPath))
            .Set("publishedCount", published)
            .Set("rereadCount", rereadCount)
            .Set("boundaryCount", _index.Boundaries.Count)
            .Set("artifacts", indexed)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"artifacts={rereadCount.ToString(CultureInfo.InvariantCulture)}/{_index.Boundaries.Count.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// The changed-path census the preparation publishes at the source boundary.
    /// </summary>
    /// <remarks>
    /// Declared by the caller and validated here; never synthesised. A control
    /// plane that invents the census it then publishes as evidence is fabricating
    /// evidence, not coordinating, and no downstream check can tell the
    /// difference because every artifact derived from it is internally
    /// consistent. C# validates the shape and passes it through; deriving it from
    /// the bound corpus stays with the PowerShell acquisition path that owns it.
    /// </remarks>
    private ListNode ReadDeclaredChangedPaths()
    {
        const string label = "changed path census";
        var path = _request.ChangedPathsPath;
        if (!File.Exists(path))
        {
            throw new ContractException($"The declared changed-path census '{path}' does not exist.");
        }
        var root = StrictJson.ReadObjectFile(path, label);
        StrictJson.RequireNoUnknownFields(root, label, "contractVersion", "kind", "changedPaths");
        StrictJson.RequireLiteral(root, "contractVersion", ChangedPathsContractVersion, label);
        StrictJson.RequireLiteral(root, "kind", "shadow-run-coordinator-changed-paths", label);

        var declared = StrictJson.RequireStringArray(root, "changedPaths", label);
        if (declared.Count == 0)
        {
            throw new ContractException($"The {label} declares no changed path; a preparation with nothing to prepare is a request fault, not an empty plan.");
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var previous = string.Empty;
        var census = new ListNode();
        foreach (var entry in declared)
        {
            if (entry.Length == 0)
            {
                throw new ContractException($"The {label} holds an empty path.");
            }
            if (!seen.Add(entry))
            {
                throw new ContractException($"The {label} repeats '{entry}'.");
            }
            // Ordinal ascending, required rather than imposed. Sorting it here
            // would hide a producer whose census order is unstable, and the order
            // reaches the published bytes.
            if (previous.Length > 0 && string.CompareOrdinal(previous, entry) >= 0)
            {
                throw new ContractException($"The {label} is not in ordinal ascending order at '{entry}'.");
            }
            previous = entry;
            census.Add(entry);
        }
        return census;
    }

    private const string ChangedPathsContractVersion = "devpilot.shadow-run-coordinator.changed-paths.v1";

    // -----------------------------------------------------------------------
    // snapshotValidateOnly / snapshotSealed / snapshotVerified
    // -----------------------------------------------------------------------
    private (MapNode Evidence, string Detail) ValidateSnapshotOnly()
    {
        var childRequest = SealRequest(validateOnly: true);
        var outcome = _invoker.Invoke("corpusSealValidate", ChildScript(), childRequest, "validateOnly");
        if (!StrictJson.RequireBool(outcome.Result, "validateOnly", "'corpusSealValidate' child result"))
        {
            throw new ContractException("The validate-only seal step reported that it was not validate-only.");
        }
        // A validate-only pass may not have produced a snapshot. If the replay
        // root exists at all, it must be empty of snapshots, because a
        // validate-only step that wrote one is not validate-only.
        if (Directory.Exists(_request.ReplayRoot) &&
            Directory.GetDirectories(_request.ReplayRoot).Length != 0)
        {
            throw new ContractException($"The validate-only seal step left a snapshot under '{_request.ReplayRoot}'.");
        }

        var evidence = new MapNode()
            .Set("validateOnly", true)
            .Set("replayRoot", _request.ReplayRoot)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, "validateOnly=true");
    }

    private (MapNode Evidence, string Detail) SealSnapshot()
    {
        var childRequest = SealRequest(validateOnly: false);
        var outcome = _invoker.Invoke(
            "corpusSeal",
            ChildScript(),
            childRequest,
            "snapshotName",
            "manifestPath",
            "manifestSha256",
            "manifestDigest");
        ApplySealResult(outcome.Result);

        var evidence = new MapNode()
            .Set("snapshotName", _sealedSnapshotName)
            .Set("manifestPath", _sealedManifestPath)
            .Set("manifestSha256", _sealedManifestDigest)
            .Set("manifestDigest", _sealedSnapshotDigest)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"snapshot={_sealedSnapshotName}");
    }

    private (MapNode Evidence, string Detail) VerifySnapshot()
    {
        if (_sealedManifestPath.Length == 0)
        {
            ReadSealResult();
        }
        if (!File.Exists(_sealedManifestPath))
        {
            throw new ContractException($"The sealed snapshot manifest '{_sealedManifestPath}' does not exist.");
        }
        // Recomputed here rather than believed: the seal step reported a digest,
        // and this step is what makes that report falsifiable.
        var actual = CanonicalJson.Sha256HexOfFile(_sealedManifestPath);
        if (!string.Equals(actual, _sealedManifestDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The sealed manifest digests to {actual}, and the seal step reported {_sealedManifestDigest}.");
        }

        const string label = "sealed snapshot manifest";
        var manifest = StrictJson.ReadObjectFile(_sealedManifestPath, label);
        var snapshotId = StrictJson.RequireString(manifest, "snapshotId", label);
        if (!string.Equals(snapshotId, _sealedSnapshotName, StringComparison.Ordinal))
        {
            throw new ContractException($"The sealed manifest names snapshot '{snapshotId}' and the seal step reported '{_sealedSnapshotName}'.");
        }

        var evidence = new MapNode()
            .Set("snapshotId", snapshotId)
            .Set("manifestSha256", actual)
            .Set("manifestPath", _sealedManifestPath);
        return (evidence, $"manifest={actual[..12]}");
    }

    private MapNode SealRequest(bool validateOnly) => new MapNode()
        .Set("contractVersion", ChildRequestContractVersion)
        .Set("toolkitRoot", _request.ToolkitRoot)
        .Set("corpusRoot", _request.CorpusRoot)
        .Set("corpusIndexSha256", _request.CorpusIndexSha256)
        .Set("recipePath", _request.CorpusRecipePath)
        .Set("replayRoot", _request.ReplayRoot)
        .Set("validateOnly", validateOnly);

    private void ApplySealResult(JsonElement result)
    {
        const string label = "'corpusSeal' child result";
        _sealedSnapshotName = StrictJson.RequireString(result, "snapshotName", label);
        _sealedManifestPath = StrictJson.RequireString(result, "manifestPath", label);
        _sealedManifestDigest = StrictJson.RequireHex(result, "manifestSha256", label, 64);
        // Two different digests, kept apart on purpose. One is the digest of the
        // manifest file's bytes, which is what proves the file has not changed.
        // The other is the manifest's own declared digest, which is the identity
        // the qualification path binds a run set to. Conflating them would let a
        // rewritten manifest satisfy a binding it should fail.
        _sealedSnapshotDigest = StrictJson.RequireHex(result, "manifestDigest", label, 64);
    }

    private void ReadSealResult()
    {
        ApplySealResult(ReadCommittedChildResult(PreparationState.SnapshotSealed, "corpusSeal", "'corpusSeal' child result"));
    }

    // -----------------------------------------------------------------------
    // runSetDeclared / runSetVerified / runSetReady
    // -----------------------------------------------------------------------
    private (MapNode Evidence, string Detail) DeclareRunSet()
    {
        if (_sealedSnapshotName.Length == 0)
        {
            ReadSealResult();
        }
        var childRequest = QualificationRequest()
            .Set("snapshotName", _sealedSnapshotName)
            .Set("manifestSha256", _sealedManifestDigest)
            .Set("manifestDigest", _sealedSnapshotDigest);
        var outcome = _invoker.Invoke("runSetDeclare", ChildScript(), childRequest, "runSetPath", "launchTokenPresent");
        ApplyDeclareResult(outcome.Result);

        var evidence = new MapNode()
            .Set("runSetPath", _runSetPath)
            .Set("snapshotName", _sealedSnapshotName)
            .Set("plannedRunCount", _request.PlannedRunCount)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"plannedRunCount={_request.PlannedRunCount.ToString(CultureInfo.InvariantCulture)}");
    }

    private (MapNode Evidence, string Detail) VerifyRunSet()
    {
        if (_runSetPath.Length == 0)
        {
            ReadDeclareResult();
        }
        var childRequest = new MapNode()
            .Set("contractVersion", ChildRequestContractVersion)
            .Set("toolkitRoot", _request.ToolkitRoot)
            .Set("runSetPath", _runSetPath)
            .Set("runSetKeyPath", _request.RunSetKeyPath);
        var outcome = _invoker.Invoke("runSetVerify", ChildScript(), childRequest, "signatureVerified", "setId");
        if (!StrictJson.RequireBool(outcome.Result, "signatureVerified", "'runSetVerify' child result"))
        {
            throw new ContractException("The declared run set did not verify under its key.");
        }
        var setId = StrictJson.RequireString(outcome.Result, "setId", "'runSetVerify' child result");

        // A genuine signature proves the declaration was made under this key. It
        // does NOT prove the declaration is about the snapshot this run sealed:
        // one key signs every declaration in an output root, so a declaration
        // left behind by an earlier subject verifies perfectly. The verified
        // manifest names its own snapshot, so the binding is checked here rather
        // than assumed by the evidence written at runSetDeclared.
        if (_sealedSnapshotName.Length == 0)
        {
            ReadSealResult();
        }
        var declaredSnapshot = StrictJson.RequireString(outcome.Result, "snapshotName", "'runSetVerify' child result");
        if (!string.Equals(declaredSnapshot, _sealedSnapshotName, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified run set is bound to snapshot '{declaredSnapshot}' and this preparation sealed '{_sealedSnapshotName}'.");
        }

        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("snapshotName", declaredSnapshot)
            .Set("signatureVerified", true)
            .Set("runSetSha256", CanonicalJson.Sha256HexOfFile(_runSetPath))
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"setId={setId}");
    }

    private (MapNode Evidence, string Detail) ConfirmRunSetReady()
    {
        if (_sealedSnapshotName.Length == 0)
        {
            ReadSealResult();
        }
        // The status read is given the FULL plan, not just the key. Supplied with
        // only the key it reports an unauthenticated evidence view that cannot
        // say whether the declaration is genuinely signed, and run-set-ready is
        // an authenticated claim.
        var childRequest = QualificationRequest()
            .Set("snapshotName", _sealedSnapshotName)
            .Set("manifestDigest", _sealedSnapshotDigest);
        var outcome = _invoker.Invoke(
            "runSetStatus",
            ChildScript(),
            childRequest,
            "launchTokenPresent",
            "plannedRunCount",
            "slotAttemptCount",
            "modelInvocationCount");

        const string label = "'runSetStatus' child result";
        // The declaration this step reports on has to be the one the previous
        // step verified. Without this, a declaration swapped between
        // runSetVerified and runSetReady would be signed off by a record whose
        // setId names a different run set entirely.
        var verifiedSetId = _state.EvidenceFor(PreparationState.RunSetVerified)?.GetText("setId");
        if (verifiedSetId is null || verifiedSetId.Length == 0)
        {
            throw new ContractException("The runSetVerified record carries no setId, so readiness cannot be tied to a verified declaration.");
        }
        var reportedSetId = StrictJson.RequireString(outcome.Result, "setId", label);
        if (!string.Equals(reportedSetId, verifiedSetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The status read reports run set '{reportedSetId}' and this preparation verified '{verifiedSetId}'.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "launchTokenPresent", label))
        {
            throw new ContractException("The run set is not ready: its launch authorization is absent.");
        }
        var planned = StrictJson.RequireInt(outcome.Result, "plannedRunCount", label, 2, 16);
        if (planned != _request.PlannedRunCount)
        {
            throw new ContractException($"The declared run set plans {planned.ToString(CultureInfo.InvariantCulture)} run(s) and the request asked for {_request.PlannedRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        // The load-bearing assertion of this whole slice: ready to launch, and
        // nothing launched. A non-zero attempt census here means the preparation
        // did something it is not allowed to do.
        var attempts = StrictJson.RequireInt(outcome.Result, "slotAttemptCount", label, 0, int.MaxValue);
        if (attempts != 0)
        {
            throw new ContractException($"The preparation observed {attempts.ToString(CultureInfo.InvariantCulture)} slot attempt(s); this coordinator prepares a run set and launches nothing.");
        }
        // Observed the same way, rather than asserted. A hard-coded zero here
        // would be a policy statement dressed as an audit: it would read exactly
        // the same on a run that had invoked a model as on one that had not.
        var models = StrictJson.RequireInt(outcome.Result, "modelInvocationCount", label, 0, int.MaxValue);
        if (models != 0)
        {
            throw new ContractException($"The preparation observed {models.ToString(CultureInfo.InvariantCulture)} model invocation(s); this coordinator invokes no model.");
        }

        var evidence = new MapNode()
            .Set("launchTokenPresent", true)
            .Set("setId", reportedSetId)
            .Set("plannedRunCount", planned)
            .Set("slotAttemptCount", attempts)
            .Set("modelInvocationCount", models)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"plannedRunCount={planned.ToString(CultureInfo.InvariantCulture)} slotAttempts=0");
    }

    private MapNode QualificationRequest() => new MapNode()
        .Set("contractVersion", ChildRequestContractVersion)
        .Set("toolkitRoot", _request.ToolkitRoot)
        .Set("qualificationRoot", _request.QualificationRoot)
        .Set("replayRoot", _request.ReplayRoot)
        .Set("reviewerRepositoryPath", _request.ReviewerRepositoryPath)
        .Set("reviewerConfigPath", _request.ReviewerConfigPath)
        .Set("operatorAlias", _request.OperatorAlias)
        .Set("pullRequestId", _request.PullRequestId)
        .Set("expectedCommit", _request.ExpectedCommit)
        .Set("requiredRef", _request.RequiredRef)
        .Set("plannedRunCount", _request.PlannedRunCount)
        .Set("runSetKeyPath", _request.RunSetKeyPath);

    private void ApplyDeclareResult(JsonElement result)
    {
        _runSetPath = StrictJson.RequireString(result, "runSetPath", "'runSetDeclare' child result");
        if (!StrictJson.RequireBool(result, "launchTokenPresent", "'runSetDeclare' child result"))
        {
            throw new ContractException("The run set declaration minted no launch authorization.");
        }
    }

    private void ReadDeclareResult()
    {
        ApplyDeclareResult(ReadCommittedChildResult(PreparationState.RunSetDeclared, "runSetDeclare", "'runSetDeclare' child result"));
    }

    private string ChildScript() => Path.Combine(_request.ToolkitRoot, "tools", ChildScriptName);

    private const string ChildRequestContractVersion = "devpilot.shadow-run-coordinator.child-request.v1";

    /// <summary>
    /// Writes the audit from the durable state alone.
    /// </summary>
    /// <remarks>
    /// Built entirely from the signed state rather than from what this process
    /// happened to do, so a preparation killed and resumed eight times publishes
    /// exactly the audit an uninterrupted one would. An audit assembled from
    /// in-memory work would silently thin out on every restart, which is the
    /// opposite of what an audit is for.
    /// </remarks>
    private void WriteAudit()
    {
        var stages = new MapNode();
        foreach (var transition in _state.Transitions)
        {
            stages.Set(PreparationStateNames.ToName(transition.State), transition.Evidence);
        }
        // Read out of the committed evidence rather than restated here. The
        // readiness transition refuses a non-zero census, so these are the
        // observed values that transition was allowed to commit on, and an audit
        // that restated them as constants would say the same thing whatever had
        // happened.
        var readiness = _state.EvidenceFor(PreparationState.RunSetReady);
        // Counted out of the durable record, not out of this process. Every
        // transition that ran a child committed that child's result digest, so
        // the census of transitions carrying one is the census of child results
        // the run stands on - and it reads the same after eight restarts as it
        // does on an uninterrupted run. The in-memory launch counter cannot see
        // a launch made by an earlier process, so it could neither prove nor
        // disprove the very thing it looked like it was proving.
        var childBackedTransitions = 0;
        foreach (var transition in _state.Transitions)
        {
            if (transition.Evidence.GetText("childResultSha256") is { Length: > 0 })
            {
                childBackedTransitions++;
            }
        }
        var audit = new MapNode()
            .Set("contractVersion", "devpilot.shadow-run-coordinator.audit.v1")
            .Set("kind", "shadow-run-coordinator-audit")
            .Set("correlationId", _request.CorrelationId)
            .Set("requestSha256", _request.RequestSha256)
            .Set("subjectSha256", CoordinatorState.SubjectDigest(_request))
            .Set("finalState", PreparationStateNames.ToName(_state.State))
            .Set("sequence", _state.Sequence);
        // A run stopped short of readiness has not OBSERVED either count, and a
        // null here would be read as zero by any consumer that coerces it - the
        // reassuring answer, arrived at by never having asked. The fields are
        // absent instead, and an explicit flag says why.
        var observed = readiness is not null;
        audit.Set("invariantCountsObserved", observed);
        if (observed)
        {
            audit
                .Set("modelInvocationCount", readiness!.Get("modelInvocationCount") ?? Node.Null())
                .Set("slotLaunchCount", readiness.Get("slotAttemptCount") ?? Node.Null());
        }
        audit
            .Set("childResultTransitionCount", childBackedTransitions)
            .Set("stages", stages);
        var transitions = new ListNode();
        foreach (var transition in _state.Transitions)
        {
            transitions.Add(new MapNode()
                .Set("sequence", transition.Sequence)
                .Set("state", PreparationStateNames.ToName(transition.State))
                .Set("evidenceSha256", transition.EvidenceSha256)
                .Set("detail", transition.Detail));
        }
        audit.Set("transitions", transitions);
        audit.Set("auditSha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(audit)));
        CanonicalJson.WriteFileAtomic(_request.AuditPath, CanonicalJson.Readable(audit));
    }
}

/// <summary>
/// Instructed halt, used by the fault suite to stop a run at an exact transition
/// boundary. It is deliberately its own type so that a halt can never be confused
/// with success, and the entry point maps it to its own exit code.
/// </summary>
internal sealed class DeliberateHaltException(PreparationState state) : Exception($"Halted after {PreparationStateNames.ToName(state)}.")
{
    internal PreparationState State { get; } = state;
}
