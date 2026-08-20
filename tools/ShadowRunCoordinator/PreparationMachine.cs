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
    SlotSupervisor supervisor,
    TextWriter log)
{
    private const string ChildScriptName = "Invoke-ShadowCoordinatorChild.ps1";

    private readonly CoordinatorRequest _request = request;
    private readonly CoordinatorState _state = state;
    private readonly byte[] _stateKey = stateKey;
    private readonly StageArtifactIndex _index = index;
    private readonly ChildToolInvoker _invoker = invoker;
    private readonly SlotSupervisor _supervisor = supervisor;
    private readonly TextWriter _log = log;

    private string _sealedSnapshotName = string.Empty;
    private string _sealedManifestPath = string.Empty;
    private string _sealedManifestDigest = string.Empty;
    private string _sealedSnapshotDigest = string.Empty;
    private string _runSetPath = string.Empty;
    private SlotPlan? _slotPlan;
    private CorpusStager? _stager;

    /// <summary>
    /// The file name the qualification path publishes its single-use launch
    /// authorization under, beside the declaration it authorizes.
    /// </summary>
    private const string PublishedLaunchTokenName = "launch-authorization.token";

    /// <summary>Runs until the target state is reached, halting early only when instructed to.</summary>
    internal void Run(PreparationState target, PreparationState? haltAfter)
    {
        var targetRank = PreparationStateNames.RankOf(target);
        var haltRank = haltAfter is { } halt ? PreparationStateNames.RankOf(halt) : -1;
        foreach (var rank in PreparationStateNames.Ranks)
        {
            if (rank > targetRank)
            {
                break;
            }
            var committed = Advance(rank);
            if (rank == haltRank)
            {
                _log.WriteLine($"halt-after {PreparationStateNames.ToName(committed)} (correlationId={_request.CorrelationId}, sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)})");
                throw new DeliberateHaltException(committed);
            }
        }
        WriteAudit();
    }

    /// <summary>Performs, or recognises as already performed, the transition at one rank.</summary>
    private PreparationState Advance(int rank)
    {
        if (PreparationStateNames.RankOf(_state.State) >= rank)
        {
            var recorded = RecordedStateAtRank(rank);
            _log.WriteLine($"skip {PreparationStateNames.ToName(recorded)} (already recorded at sequence {SequenceOf(recorded)}, correlationId={_request.CorrelationId})");
            RehydrateFor(recorded);
            return recorded;
        }
        // The terminal rank is the one place where WHICH state gets committed is
        // not known before the work is done, because it is the supervised run's
        // own artifact that says whether the run completed, failed or timed out.
        if (rank == PreparationStateNames.TerminalRank)
        {
            var (outcome, terminalEvidence, terminalDetail) = VerifySlot1Terminal();
            _log.WriteLine($"enter {PreparationStateNames.ToName(outcome)} (correlationId={_request.CorrelationId})");
            _state.Commit(_request, _stateKey, outcome, terminalEvidence, terminalDetail);
            _log.WriteLine($"commit {PreparationStateNames.ToName(outcome)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} evidence={_state.EvidenceDigestOf(outcome)} detail={terminalDetail}");
            return outcome;
        }

        // The running state is committed by its own transition, in the middle of
        // it rather than at the end: the identity of a child has to be durable
        // BEFORE the wait that may outlive this process.
        if (rank == PreparationStateNames.RankOf(PreparationState.Slot1Running))
        {
            _log.WriteLine($"enter slot1Running (correlationId={_request.CorrelationId})");
            RunSlot1();
            return PreparationState.Slot1Running;
        }

        var next = PreparationStateNames.StateAtRank(rank);
        _log.WriteLine($"enter {PreparationStateNames.ToName(next)} (correlationId={_request.CorrelationId})");
        var (evidence, detail) = next switch
        {
            PreparationState.RequestValidated => ValidateRequest(),
            PreparationState.CorpusStaging => StageCorpus(),
            PreparationState.CorpusPublished => PublishCorpus(),
            PreparationState.CorpusValidated => ValidateCorpus(),
            PreparationState.RecipePlanned => PlanRecipe(),
            PreparationState.SnapshotValidateOnly => ValidateSnapshotOnly(),
            PreparationState.SnapshotSealed => SealSnapshot(),
            PreparationState.SnapshotVerified => VerifySnapshot(),
            PreparationState.RunSetDeclared => DeclareRunSet(),
            PreparationState.RunSetVerified => VerifyRunSet(),
            PreparationState.RunSetReady => ConfirmRunSetReady(),
            PreparationState.Slot1Authorized => AuthorizeSlot1(),
            PreparationState.Slot1Launching => BeginSlot1Launch(),
            PreparationState.Slot1TerminalObserved => ObserveSlot1Terminal(),
            _ => throw new ContractException($"'{PreparationStateNames.ToName(next)}' is not a transition this coordinator performs.")
        };
        _state.Commit(_request, _stateKey, next, evidence, detail);
        _log.WriteLine($"commit {PreparationStateNames.ToName(next)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} evidence={_state.EvidenceDigestOf(next)} detail={detail}");
        return next;
    }

    /// <summary>
    /// The state actually recorded at a rank a resume is skipping over. It is read
    /// from the durable transitions rather than assumed, because the terminal rank
    /// could hold any one of three.
    /// </summary>
    private PreparationState RecordedStateAtRank(int rank)
    {
        foreach (var transition in _state.Transitions)
        {
            if (PreparationStateNames.RankOf(transition.State) == rank)
            {
                return transition.State;
            }
        }
        // A record can be past a rank without carrying its transition only if it
        // was truncated or rewritten; guessing which sibling to name would be an
        // invention.
        throw new ContractException(
            $"The state record stands at '{PreparationStateNames.ToName(_state.State)}' but carries no transition at rank {rank.ToString(CultureInfo.InvariantCulture)}, so the resume has nothing to skip over.");
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
            case PreparationState.CorpusStaging:
                if (_request.CorpusStagingRequested)
                {
                    Stager().RecheckStaged(CommittedEvidence(PreparationState.CorpusStaging));
                }
                break;
            case PreparationState.SnapshotSealed:
                ReadSealResult();
                break;
            case PreparationState.RecipePlanned:
                RecheckRecordedArtifacts();
                break;
            case PreparationState.RunSetDeclared:
                ReadDeclareResult();
                break;
            case PreparationState.Slot1Authorized:
                ReadSlotPlanResult();
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
    // corpusStaging / corpusPublished - where the corpus is built, not found
    // -----------------------------------------------------------------------

    /// <summary>
    /// The stage declaration this run builds from, read once and checked against
    /// both the authorization's digest and the request that carries it.
    /// </summary>
    private CorpusStager Stager()
    {
        if (_stager is not null)
        {
            return _stager;
        }
        var authorization = _request.RequireCorpusStaging();
        // The digest is checked inside Load, against the same buffer Load parses,
        // so the declaration that is obeyed is the declaration that was proven.
        var declaration = CorpusStageRequest.Load(authorization.RequestPath, authorization.RequestSha256);
        var stager = new CorpusStager(_request, declaration, _log);
        // Two files that both describe one subject are two chances to describe two
        // subjects. They are reconciled here, once, before a single byte is read.
        stager.RequireAgreementWithRequest();
        _stager = stager;
        return stager;
    }

    /// <summary>
    /// The evidence a previous transition committed, read back from the signed
    /// record rather than recomputed.
    /// </summary>
    private MapNode CommittedEvidence(PreparationState state)
    {
        foreach (var transition in _state.Transitions)
        {
            if (transition.State == state)
            {
                return transition.Evidence;
            }
        }
        throw new ContractException(
            $"The state record carries no '{PreparationStateNames.ToName(state)}' transition, so there is no evidence to continue from.");
    }

    /// <summary>
    /// The evidence a run that builds no corpus commits at these two ranks.
    /// </summary>
    /// <remarks>
    /// A no-op, and recorded as one. The alternative - skipping the rank - would
    /// make the sequence numbers of a staging run and a non-staging run differ,
    /// and every downstream check that names a sequence would then have to know
    /// which kind of run it was reading. An explicit false is cheaper than that
    /// and says more.
    /// </remarks>
    private (MapNode Evidence, string Detail) NoCorpusConstruction(string phase)
    {
        var reason = _request.CorpusStage is null
            ? "the request carries no corpusStage section"
            : "the request's corpusStage section sets stagingEnabled to false";
        var evidence = new MapNode()
            .Set("staged", false)
            .Set("phase", phase)
            .Set("reason", reason)
            .Set("corpusRoot", _request.CorpusRoot);
        return (evidence, "staged=false");
    }

    private (MapNode Evidence, string Detail) StageCorpus() =>
        _request.CorpusStagingRequested ? Stager().Stage() : NoCorpusConstruction("staging");

    private (MapNode Evidence, string Detail) PublishCorpus()
    {
        if (!_request.CorpusStagingRequested)
        {
            return NoCorpusConstruction("publish");
        }
        return Stager().Publish(CommittedEvidence(PreparationState.CorpusStaging));
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

    private MapNode SealRequest(bool validateOnly)
    {
        // The request binds a recipe PATH; the record binds its CONTENT. A resume
        // skips corpusValidated, so without this the file at that path could have
        // been rewritten between validation and the seal that consumes it, and the
        // snapshot would be sealed from a recipe this preparation never validated.
        var committed = _state.EvidenceFor(PreparationState.CorpusValidated)?.GetText("recipeSha256");
        if (committed is null || committed.Length == 0)
        {
            throw new ContractException("The corpusValidated record carries no recipe digest, so the seal cannot be tied to the recipe this run validated.");
        }
        if (!File.Exists(_request.CorpusRecipePath))
        {
            throw new ContractException($"The corpus recipe '{_request.CorpusRecipePath}' validated by this run is gone.");
        }
        var current = CanonicalJson.Sha256HexOfFile(_request.CorpusRecipePath);
        if (!string.Equals(current, committed, StringComparison.Ordinal))
        {
            throw new ContractException($"The corpus recipe at '{_request.CorpusRecipePath}' now hashes to {current} and this run validated {committed}. The recipe changed under the preparation that bound it.");
        }
        return new MapNode()
            .Set("contractVersion", ChildRequestContractVersion)
            .Set("toolkitRoot", _request.ToolkitRoot)
            .Set("corpusRoot", _request.CorpusRoot)
            .Set("corpusIndexSha256", _request.CorpusIndexSha256)
            .Set("recipePath", _request.CorpusRecipePath)
            .Set("recipeSha256", committed)
            .Set("replayRoot", _request.ReplayRoot)
            .Set("validateOnly", validateOnly);
    }

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

    // -----------------------------------------------------------------------
    // slot1Authorized / slot1Launching / slot1Running / slot1TerminalObserved
    // / slot1Terminal{Verified,Failed,TimedOut}
    // -----------------------------------------------------------------------

    /// <summary>
    /// Establishes that this run may launch one slot, and binds every identity
    /// the launch will be judged against.
    /// </summary>
    /// <remarks>
    /// Authorization is separated from launching because the launch consumes
    /// something that cannot be un-consumed: the PowerShell owner makes its
    /// attempt record with CreateNew before it starts any work, so there is
    /// exactly one chance. Everything that could refuse the launch is therefore
    /// checked and committed BEFORE any state exists that says a launch is due.
    ///
    /// Nothing here judges the run. It reads a plan, compares identities, hashes
    /// a token, and refuses on mismatch.
    /// </remarks>
    private (MapNode Evidence, string Detail) AuthorizeSlot1()
    {
        var authorization = _request.RequireSlotAuthorization();

        // The declaration this slot will consume must be the one this run
        // verified and then observed ready. Reading both records rather than one
        // is the point: readiness alone would let a run set verified under a
        // different subject satisfy a readiness record written for this one.
        var verified = _state.EvidenceFor(PreparationState.RunSetVerified)
            ?? throw new ContractException("The run holds no runSetVerified record, so there is no verified declaration to authorize a launch against.");
        var ready = _state.EvidenceFor(PreparationState.RunSetReady)
            ?? throw new ContractException("The run holds no runSetReady record, so nothing has been observed ready to launch.");
        var verifiedSetId = verified.GetText("setId") ?? throw new ContractException("The runSetVerified record carries no setId.");
        var readySetId = ready.GetText("setId") ?? throw new ContractException("The runSetReady record carries no setId.");
        if (!string.Equals(verifiedSetId, readySetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified declaration is '{verifiedSetId}' and readiness was observed for '{readySetId}'.");
        }

        // The declaration file itself has to be the bytes the verification was
        // committed against. A re-declared run set at the same path would verify
        // perfectly under the same key and be a different set entirely.
        if (_runSetPath.Length == 0)
        {
            ReadDeclareResult();
        }
        var committedRunSetSha = verified.GetText("runSetSha256")
            ?? throw new ContractException("The runSetVerified record carries no declaration digest to bind the launch to.");
        if (!File.Exists(_runSetPath))
        {
            throw new ContractException($"The declaration at '{_runSetPath}' is gone; no launch may be authorized against a declaration this run no longer has.");
        }
        var actualRunSetSha = CanonicalJson.Sha256HexOfFile(_runSetPath);
        if (!string.Equals(actualRunSetSha, committedRunSetSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The declaration at '{_runSetPath}' now digests to {actualRunSetSha} and was verified as {committedRunSetSha}.");
        }

        // The token is read here and never leaves this method as text. What is
        // committed, logged and audited is its digest, computed the way the
        // qualification path computes it so that the comparison below is a real
        // check and not an echo.
        var tokenHash = ReadLaunchTokenHash(authorization.LaunchAuthorizationTokenPath);

        // An authorization check, and therefore this coordinator's own: the
        // credential presented must be the credential the set published. It is
        // made here, before any child runs, because a wrong token cannot rebuild
        // the plan at all - the reviewed code would refuse it as an unreproducible
        // plan, which reads like a broken declaration rather than like the
        // ordinary mistake it is. The reviewed inventory check still runs inside
        // the child; this one only makes the refusal legible and cheap.
        var runSetDirectory = Path.GetDirectoryName(_runSetPath);
        if (runSetDirectory is { Length: > 0 })
        {
            var publishedTokenPath = Path.Combine(runSetDirectory, PublishedLaunchTokenName);
            if (!File.Exists(publishedTokenPath))
            {
                throw new ContractException($"The published run set under '{runSetDirectory}' carries no launch-authorization token, so no launch can be authorized against it.");
            }
            // Compared as digests so that neither token's text can be recovered
            // from a message, a core dump or a log this method might later grow.
            if (!string.Equals(ReadLaunchTokenHash(publishedTokenPath), tokenHash, StringComparison.Ordinal))
            {
                throw new ContractException(
                    "The launch-authorization token this request names is not the token the published run set carries, " +
                    "so the plan it was sealed under cannot be reproduced.");
            }
        }

        var plan = ReadSlotPlan(RequestSlotPlan());

        if (!string.Equals(plan.SetId, verifiedSetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan is built for run set '{plan.SetId}' and this run verified '{verifiedSetId}'.");
        }
        if (!string.Equals(plan.SlotName, CoordinatorRequest.SupervisedSlotName, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan describes slot '{plan.SlotName}'; this coordinator supervises '{CoordinatorRequest.SupervisedSlotName}' only.");
        }
        if (!string.Equals(plan.LaunchAuthorizationHash, tokenHash, StringComparison.Ordinal))
        {
            // Deliberately no digests in the message. The plan's hash is sealed
            // into the plan digest, so printing both sides of a failed comparison
            // would publish a working oracle for guessing the token.
            throw new ContractException("The launch-authorization token this request names does not hash to the authorization the declaration sealed.");
        }
        if (!string.Equals(plan.Head, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan is built at toolkit head {plan.Head} and this request authorizes {_request.ToolkitHead}.");
        }
        if (!string.Equals(plan.RequiredRef, _request.RequiredRef, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan requires ref '{plan.RequiredRef}' and this request authorizes '{_request.RequiredRef}'.");
        }
        if (!plan.HeadClean)
        {
            throw new ContractException("The toolkit working tree is not clean, so the head a launch would be attributed to is not the head that would run.");
        }
        // A live head check of this process's own view, so that a plan built
        // moments ago cannot carry a head this run has since moved off.
        var observedHead = GitHead.Resolve(_request.ToolkitRoot);
        if (!string.Equals(observedHead, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The toolkit is at head {observedHead} and this request authorizes {_request.ToolkitHead}.");
        }
        // One shot. An attempt record that already exists means this declaration's
        // single launch authorization was consumed - by this coordinator before a
        // crash, or by a hand-run of the PowerShell path. Either way, authorizing
        // a launch now would be authorizing a second one.
        if (plan.SlotAttemptExists)
        {
            throw new ContractException(
                $"Slot '{plan.SlotName}' already carries an attempt record, so its single-use launch authorization is spent. " +
                "This coordinator does not launch a slot twice.");
        }
        if (plan.SlotTerminalExists)
        {
            throw new ContractException($"Slot '{plan.SlotName}' already carries terminal evidence, so its run is over and cannot be authorized again.");
        }

        plan.Deadlines.RequireConsistent("qualification plan");

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("slotName", plan.SlotName)
            .Set("launchAuthorizationHash", plan.LaunchAuthorizationHash)
            .Set("reviewerScriptSha256", plan.ReviewerScriptSha256)
            .Set("slotTerminalPath", plan.SlotTerminalPath)
            .Set("slotStateDir", plan.SlotStateDir)
            .Set("head", plan.Head)
            .Set("requiredRef", plan.RequiredRef)
            .Set("headClean", true)
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("authorization", authorization.Describe())
            .Set("childResultSha256", plan.ChildResultSha256);
        return (evidence, $"setId={plan.SetId} slot={plan.SlotName} planDigest={plan.PlanDigest}");
    }

    /// <summary>
    /// The durable statement that a launch is now due. It starts nothing.
    /// </summary>
    /// <remarks>
    /// This looks like a state with no work in it, and that is exactly its value.
    /// A crash between "authorized" and "running" is otherwise unreadable: there
    /// is no way to tell a run that had not started its child yet from one that
    /// had started it and died before it could record it. With this state
    /// committed first, the record distinguishes the two, and the resume path can
    /// refuse rather than guess.
    /// </remarks>
    private (MapNode Evidence, string Detail) BeginSlot1Launch()
    {
        var authorized = _state.EvidenceFor(PreparationState.Slot1Authorized)
            ?? throw new ContractException("Nothing authorized a launch, so no launch is due.");
        var setId = authorized.GetText("setId") ?? throw new ContractException("The slot1Authorized record carries no setId.");
        var planDigest = authorized.GetText("planDigest") ?? throw new ContractException("The slot1Authorized record carries no plan digest.");
        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("slotName", CoordinatorRequest.SupervisedSlotName)
            .Set("launchDue", true);
        return (evidence, $"slot={CoordinatorRequest.SupervisedSlotName} planDigest={planDigest}");
    }

    /// <summary>
    /// Starts the supervised child, makes its identity durable, then watches it
    /// until it stops or a plan deadline says to stop watching.
    /// </summary>
    private void RunSlot1()
    {
        var authorized = _state.EvidenceFor(PreparationState.Slot1Authorized)
            ?? throw new ContractException("Nothing authorized a launch, so nothing may be run.");
        var authorizedDigest = authorized.GetText("planDigest") ?? throw new ContractException("The slot1Authorized record carries no plan digest.");

        // Re-derived here rather than re-read from the authorization's committed
        // result, and that difference is the whole check. The committed result
        // records the world as it was when the launch was authorized; what has to
        // be true is that the slot is STILL unattempted at the instant before the
        // irreversible step. A resumed run reading its own older answer would
        // relaunch a slot something else had started in the meantime. Deriving a
        // plan launches nothing.
        //
        // Carried under its own step name, and with any previous answer deleted
        // first, because the invoker adopts a valid result for the same step and
        // request rather than re-running it. Adoption is right for work that must
        // not repeat; it is wrong for a probe, whose previous answer is worthless
        // by definition.
        var probePath = Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-slotPrelaunch.result.json");
        if (File.Exists(probePath))
        {
            File.Delete(probePath);
        }
        var plan = ReadSlotPlan(RequestSlotPlan("slotPrelaunch"));
        if (!string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The plan now digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }

        // The last gate before the irreversible step. The authorization proved
        // there was no attempt record when it was written; time has passed since,
        // and this run has to be the one that creates it.
        if (plan.SlotAttemptExists || plan.SlotTerminalExists)
        {
            throw new ContractException(
                $"Slot '{plan.SlotName}' acquired attempt or terminal evidence between authorization and launch, so its single launch has already been used.");
        }

        var childRequest = SlotChildRequest(plan.Authorization)
            .Set("expectedPlanDigest", plan.PlanDigest)
            .Set("expectedSetId", plan.SetId);
        var launch = _supervisor.Start("slotRun", ChildScript(), childRequest);

        // Committed BEFORE the wait. This is the whole reason the supervisor is
        // two-phase: a coordinator killed during a slot that ran for an hour must
        // come back able to name the child it left behind, and a record written
        // after the wait would only ever describe runs that did not need it.
        var running = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("slotName", plan.SlotName)
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("child", launch.DescribeIdentity())
            .Set("supervisionStartedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        _state.Commit(_request, _stateKey, PreparationState.Slot1Running, running, $"childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        _log.WriteLine($"commit slot1Running sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");

        var observation = _supervisor.Await(launch, plan.Deadlines, plan.SlotStateDir);
        _log.WriteLine($"observed slot child disposition={observation.Disposition} exitCode={observation.ExitCode.ToString(CultureInfo.InvariantCulture)}");
        _observedRun = observation;
        _observedLaunch = launch;
    }

    /// <summary>
    /// Reads what the supervised child left behind, without deciding what it
    /// means.
    /// </summary>
    /// <remarks>
    /// The exit code is recorded and is deliberately not acted upon. A failed
    /// qualification slot exits non-zero by design - the PowerShell owner
    /// propagates the reviewed run's own exit code - so treating non-zero as a
    /// child failure would turn every legitimately failed run into a coordinator
    /// error. What this transition requires is not success but EVIDENCE: the
    /// owner's immutable terminal artifact. An exit of zero with no terminal
    /// artifact is refused exactly as loudly as a hang.
    /// </remarks>
    private (MapNode Evidence, string Detail) ObserveSlot1Terminal()
    {
        var running = _state.EvidenceFor(PreparationState.Slot1Running)
            ?? throw new ContractException("No slot was recorded running, so there is nothing to observe.");
        if (_slotPlan is null)
        {
            ReadSlotPlanResult();
        }
        var plan = _slotPlan!;

        if (_observedRun is null || _observedLaunch is null)
        {
            (_observedLaunch, _observedRun) = ResumeSupervision(running, plan);
        }
        var launch = _observedLaunch!;
        var observation = _observedRun!;

        // A child this coordinator stopped is reported as stopped, before anything
        // looks for a result. Falling through to "there is no result file" would
        // be true and useless: it describes the consequence of the deadline rather
        // than the deadline, and the operator has to know which budget ran out.
        if (observation.Disposition is SlotObservation.HardDeadlineKill or SlotObservation.ActivityDeadlineKill)
        {
            throw new ChildFailureException(
                $"The supervised slot was stopped by this coordinator on a plan deadline ({observation.Disposition}) after " +
                $"{observation.ObservedSeconds.ToString(CultureInfo.InvariantCulture)} second(s). " +
                "A run this coordinator ended has no terminal evidence of its own, and none is invented for it.");
        }

        var outcome = _supervisor.ReadResult(
            launch,
            "terminalWritten",
            "terminalPath",
            "childExitCode",
            "slotName",
            "setId",
            "planDigest");
        const string label = "'slotRun' child result";
        if (!StrictJson.RequireBool(outcome.Result, "terminalWritten", label))
        {
            throw new ContractException(
                $"The supervised slot produced no terminal evidence. A run that ends without the artifact its owner writes is unfinished, " +
                "whatever it exited with, and this coordinator will not summarise it.");
        }
        StrictJson.RequireLiteral(outcome.Result, "slotName", plan.SlotName, label);
        StrictJson.RequireLiteral(outcome.Result, "setId", plan.SetId, label);
        StrictJson.RequireLiteral(outcome.Result, "planDigest", plan.PlanDigest, label);
        var terminalPath = StrictJson.RequireString(outcome.Result, "terminalPath", label);
        if (!PathsAreSame(terminalPath, plan.SlotTerminalPath))
        {
            throw new ContractException($"The supervised slot reports terminal evidence at '{terminalPath}' and the plan places it at '{plan.SlotTerminalPath}'.");
        }
        if (!File.Exists(terminalPath))
        {
            throw new ContractException($"The supervised slot reports terminal evidence at '{terminalPath}', which does not exist.");
        }

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("slotName", plan.SlotName)
            .Set("terminalPath", terminalPath)
            .Set("terminalSha256", CanonicalJson.Sha256HexOfFile(terminalPath))
            .Set("supervision", observation.Describe())
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"disposition={observation.Disposition} childExitCode={observation.ExitCode.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Has the reviewed verifier read the terminal evidence, and records which of
    /// the three durable endings this run reached.
    /// </summary>
    /// <remarks>
    /// The status this commits is a passthrough. The words complete, failed and
    /// timedOut are the owner's, written into an immutable artifact and checked
    /// here for structure, signature, binding and immutability - never for
    /// plausibility. This coordinator has no opinion about whether a run should
    /// have failed, and holds no rule that could form one.
    /// </remarks>
    private (PreparationState Outcome, MapNode Evidence, string Detail) VerifySlot1Terminal()
    {
        var observed = _state.EvidenceFor(PreparationState.Slot1TerminalObserved)
            ?? throw new ContractException("No terminal evidence was observed, so there is nothing to verify.");
        if (_slotPlan is null)
        {
            ReadSlotPlanResult();
        }
        var plan = _slotPlan!;
        var observedTerminalSha = observed.GetText("terminalSha256")
            ?? throw new ContractException("The slot1TerminalObserved record carries no terminal digest.");

        var childRequest = SlotChildRequest(plan.Authorization)
            .Set("expectedPlanDigest", plan.PlanDigest)
            .Set("expectedSetId", plan.SetId);
        var outcome = _invoker.Invoke(
            "slotVerify",
            ChildScript(),
            childRequest,
            "terminalStatus",
            "terminalExitCode",
            "terminalTimedOut",
            "terminalImmutable",
            "terminalSetId",
            "terminalPlanDigest",
            "terminalSlot",
            "terminalSha256",
            "signatureVerified",
            "inventoryVerified",
            "slotAttemptCount",
            "modelInvocationCount");
        const string label = "'slotVerify' child result";

        // The bytes the verifier read must be the bytes this run observed. The
        // artifact is written read-only by its owner, so a changed digest here is
        // a tampered or replaced artifact rather than an ordinary race.
        var verifiedTerminalSha = StrictJson.RequireHex(outcome.Result, "terminalSha256", label, 64);
        if (!string.Equals(verifiedTerminalSha, observedTerminalSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified terminal evidence digests to {verifiedTerminalSha} and this run observed {observedTerminalSha}.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "terminalImmutable", label))
        {
            throw new ContractException("The terminal evidence is writable, so it is not the immutable record its contract requires.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "signatureVerified", label))
        {
            throw new ContractException("The declaration this terminal evidence belongs to did not verify under its key.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "inventoryVerified", label))
        {
            throw new ContractException("The published inventory for this run set did not verify, so its terminal evidence stands on nothing.");
        }
        StrictJson.RequireLiteral(outcome.Result, "terminalSetId", plan.SetId, label);
        StrictJson.RequireLiteral(outcome.Result, "terminalPlanDigest", plan.PlanDigest, label);
        StrictJson.RequireLiteral(outcome.Result, "terminalSlot", plan.SlotName, label);

        // Exactly one attempt, and it is this one. A second attempt record would
        // mean something launched the slot again behind this coordinator's back.
        var attempts = StrictJson.RequireInt(outcome.Result, "slotAttemptCount", label, 0, int.MaxValue);
        if (attempts != 1)
        {
            throw new ContractException($"The run set carries {attempts.ToString(CultureInfo.InvariantCulture)} slot attempt(s); this coordinator supervises exactly one.");
        }
        // Observed, not asserted. This coordinator invokes no model, but the run
        // it supervised may have invoked several, and reporting the census it was
        // given is the only honest thing to do with it.
        var models = StrictJson.RequireInt(outcome.Result, "modelInvocationCount", label, 0, int.MaxValue);

        var status = StrictJson.RequireString(outcome.Result, "terminalStatus", label);
        var timedOut = StrictJson.RequireBool(outcome.Result, "terminalTimedOut", label);
        var exitCode = StrictJson.RequireInt(outcome.Result, "terminalExitCode", label, int.MinValue, int.MaxValue);
        var state = status switch
        {
            "complete" => PreparationState.Slot1TerminalVerified,
            "failed" => PreparationState.Slot1TerminalFailed,
            "timedOut" => PreparationState.Slot1TerminalTimedOut,
            _ => throw new ContractException($"The terminal evidence reports status '{status}', which is not one of the three endings its contract allows.")
        };
        // The two statements the artifact makes about a timeout have to agree. A
        // 'complete' that also claims to have timed out is a corrupt record, and
        // picking whichever field suited would be inventing a reading.
        if (timedOut != (state == PreparationState.Slot1TerminalTimedOut))
        {
            throw new ContractException($"The terminal evidence reports status '{status}' and a timedOut flag of {(timedOut ? "true" : "false")}, which contradict each other.");
        }

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("slotName", plan.SlotName)
            .Set("terminalStatus", status)
            .Set("terminalExitCode", exitCode)
            .Set("terminalTimedOut", timedOut)
            .Set("terminalSha256", verifiedTerminalSha)
            .Set("signatureVerified", true)
            .Set("inventoryVerified", true)
            .Set("slotAttemptCount", attempts)
            .Set("modelInvocationCount", models)
            .Set("childResultSha256", outcome.ResultSha256);
        return (state, evidence, $"terminalStatus={status} attempts=1 modelInvocations={models.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Re-attaches to a slot a previous run launched, or refuses if it cannot.
    /// </summary>
    /// <remarks>
    /// There are only two honest outcomes here. Either the recorded child is
    /// still alive, in which case this run waits for it exactly as the launching
    /// run would have; or it is gone, in which case its terminal artifact - if it
    /// wrote one - is the whole of what is known and the exit code is
    /// unrecoverable. Relaunching is not among the options: the attempt record is
    /// spent.
    /// </remarks>
    private (SlotLaunch Launch, SlotObservation Observation) ResumeSupervision(MapNode running, SlotPlan plan)
    {
        var child = running.Get("child") as MapNode
            ?? throw new ContractException("The slot1Running record carries no child identity, so a resumed run cannot find what it left behind.");
        var processId = child.GetInteger("childProcessId")
            ?? throw new ContractException("The slot1Running record carries no child process id.");
        var startedAt = child.GetText("childStartedAtUtc") is { Length: > 0 } recordedStart
            ? recordedStart
            : throw new ContractException("The slot1Running record carries no child start time, so a recycled process id could be mistaken for the child.");
        var childRequestSha = child.GetText("childRequestSha256")
            ?? throw new ContractException("The slot1Running record carries no child request digest.");

        var launch = _supervisor.Adopt("slotRun", childRequestSha, (int)processId, startedAt);
        _log.WriteLine($"resume supervising recorded slot child processId={processId.ToString(CultureInfo.InvariantCulture)} startedAtUtc={startedAt}");
        var observation = _supervisor.Await(launch, plan.Deadlines, plan.SlotStateDir);
        return (launch, observation);
    }

    /// <summary>
    /// Reads the single-use launch token and returns only its digest, computed
    /// the way the qualification path computes it.
    /// </summary>
    /// <remarks>
    /// The token text is never returned, committed, logged or audited. What a
    /// reader of the state file learns is that a token hashing to a particular
    /// value was presented, which is what the plan digest already seals - so the
    /// record adds a binding without adding a secret.
    /// </remarks>
    private static string ReadLaunchTokenHash(string tokenPath)
    {
        if (!File.Exists(tokenPath))
        {
            throw new ContractException($"The launch-authorization token at '{tokenPath}' does not exist, so no launch can be authorized.");
        }
        var token = File.ReadAllText(tokenPath, StrictJson.StrictUtf8).Trim();
        if (token.Length != 64 || !token.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f'))
        {
            throw new ContractException($"The launch-authorization token at '{tokenPath}' is not 64 lowercase hex characters.");
        }
        return CanonicalJson.Sha256HexOfText(token);
    }

    private MapNode SlotChildRequest(SlotAuthorization authorization)
    {
        if (_sealedSnapshotName.Length == 0)
        {
            ReadSealResult();
        }
        return QualificationRequest()
            .Set("snapshotName", _sealedSnapshotName)
            .Set("manifestDigest", _sealedSnapshotDigest)
            .Set("reviewerScriptPath", authorization.ReviewerScriptPath)
            .Set("slotName", authorization.Name)
            .Set("launchAuthorizationTokenPath", authorization.LaunchAuthorizationTokenPath);
    }

    private ChildOutcome RequestSlotPlan(string step = "slotPlan")
    {
        var authorization = _request.RequireSlotAuthorization();
        return _invoker.Invoke(
            step,
            ChildScript(),
            SlotChildRequest(authorization),
            "setId",
            "planDigest",
            "launchAuthorizationHash",
            "reviewerScriptSha256",
            "slotName",
            "slotStateDir",
            "slotTerminalPath",
            "slotTimeoutSeconds",
            "progressTimeoutSeconds",
            "perCallTimeoutSeconds",
            "slotAttemptExists",
            "slotTerminalExists",
            "head",
            "requiredRef",
            "headClean");
    }

    private SlotPlan ReadSlotPlan(ChildOutcome outcome)
    {
        const string label = "'slotPlan' child result";
        var authorization = _request.RequireSlotAuthorization();
        var plan = new SlotPlan(
            StrictJson.RequireString(outcome.Result, "setId", label),
            StrictJson.RequireHex(outcome.Result, "planDigest", label, 64),
            StrictJson.RequireHex(outcome.Result, "launchAuthorizationHash", label, 64),
            StrictJson.RequireHex(outcome.Result, "reviewerScriptSha256", label, 64),
            StrictJson.RequireString(outcome.Result, "slotName", label),
            StrictJson.RequireString(outcome.Result, "slotStateDir", label),
            StrictJson.RequireString(outcome.Result, "slotTerminalPath", label),
            StrictJson.RequireBool(outcome.Result, "slotAttemptExists", label),
            StrictJson.RequireBool(outcome.Result, "slotTerminalExists", label),
            StrictJson.RequireString(outcome.Result, "head", label),
            StrictJson.RequireString(outcome.Result, "requiredRef", label),
            StrictJson.RequireBool(outcome.Result, "headClean", label),
            new SlotDeadlines(
                StrictJson.RequireInt(outcome.Result, "slotTimeoutSeconds", label, 1, 14400),
                StrictJson.RequireInt(outcome.Result, "progressTimeoutSeconds", label, 0, 14400),
                StrictJson.RequireInt(outcome.Result, "perCallTimeoutSeconds", label, 1, 14400),
                authorization.SupervisionGraceSeconds),
            authorization,
            outcome.ResultSha256);
        _slotPlan = plan;
        return plan;
    }

    private void ReadSlotPlanResult()
    {
        var committed = _state.EvidenceFor(PreparationState.Slot1Authorized);
        var result = ReadCommittedChildResult(PreparationState.Slot1Authorized, "slotPlan", "'slotPlan' child result");
        var plan = ReadSlotPlan(new ChildOutcome(
            0,
            Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-slotPlan.result.json"),
            result,
            committed?.GetText("childResultSha256") ?? string.Empty));
        // The plan is re-read from the result the authorization committed rather
        // than re-derived, so a resumed run works from the same plan the launch
        // was authorized against. The digest comparison below is what makes that
        // safe: a committed result that no longer matches its own recorded digest
        // is refused by the reader before it gets here.
        var authorizedDigest = committed?.GetText("planDigest");
        if (authorizedDigest is not null && !string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The resumed plan digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }
    }

    private static bool PathsAreSame(string left, string right)
    {
        try
        {
            return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private SlotObservation? _observedRun;
    private SlotLaunch? _observedLaunch;

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
        .Set("runSetKeyPath", _request.RunSetKeyPath)
        // Carried on every qualification step, including the ones the preparation
        // slice already had. The plan digest seals the agent's path and content
        // hash, so a declaration made without naming the agent a later slot names
        // would be a declaration that slot could never reproduce. Empty means the
        // production agent, which is what the preparation slice always meant.
        .Set("reviewerScriptPath", _request.Slot?.ReviewerScriptPath ?? string.Empty);

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
        // The supervised slice reports separately, and only when it happened. A
        // preparation that never authorized a launch says so rather than
        // publishing zeroed slot fields that would read like a slot that ran and
        // did nothing.
        var terminal = _state.EvidenceAtRank(PreparationStateNames.TerminalRank);
        var supervised = terminal is not null;
        audit.Set("slotSupervised", supervised);
        if (supervised)
        {
            // Every one of these is a passthrough of what the reviewed verifier
            // read out of the owner's immutable artifact. This coordinator adds
            // no interpretation, and the audit must not read as though it had.
            audit
                .Set("slotName", terminal!.Get("slotName") ?? Node.Null())
                .Set("slotSetId", terminal.Get("setId") ?? Node.Null())
                .Set("slotPlanDigest", terminal.Get("planDigest") ?? Node.Null())
                .Set("slotTerminalStatus", terminal.Get("terminalStatus") ?? Node.Null())
                .Set("slotTerminalExitCode", terminal.Get("terminalExitCode") ?? Node.Null())
                .Set("slotTerminalTimedOut", terminal.Get("terminalTimedOut") ?? Node.Null())
                .Set("slotTerminalSha256", terminal.Get("terminalSha256") ?? Node.Null())
                .Set("slotAttemptCount", terminal.Get("slotAttemptCount") ?? Node.Null())
                .Set("slotModelInvocationCount", terminal.Get("modelInvocationCount") ?? Node.Null());
            var supervision = _state.EvidenceFor(PreparationState.Slot1TerminalObserved)?.Get("supervision");
            audit.Set("slotSupervision", supervision ?? Node.Null());
        }
        // Named for a reader who wants the one-line answer to "did this write
        // anything anywhere". The whole slice has no delivery path and no
        // provider write, so the claim is structural rather than measured - and
        // it is stated here so that a future slice that gained one would have to
        // come and change a line that says it did not.
        audit.Set("deliveryMode", "previewOnly");
        audit.Set("providerWriteCount", 0);
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

/// <summary>
/// The qualification plan as the coordinator needs to see it: identities to bind
/// against, paths to watch, budgets to supervise within, and two facts about
/// whether the single launch has been spent.
/// </summary>
/// <remarks>
/// It is a read of the reviewed PowerShell plan, never a second construction of
/// one. Nothing here selects a model, orders work, or decides what the run should
/// do; those live in the plan builder this record merely reports.
/// </remarks>
internal sealed record SlotPlan(
    string SetId,
    string PlanDigest,
    string LaunchAuthorizationHash,
    string ReviewerScriptSha256,
    string SlotName,
    string SlotStateDir,
    string SlotTerminalPath,
    bool SlotAttemptExists,
    bool SlotTerminalExists,
    string Head,
    string RequiredRef,
    bool HeadClean,
    SlotDeadlines Deadlines,
    SlotAuthorization Authorization,
    string ChildResultSha256);
