using System.Globalization;
using System.Security.Cryptography;
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
    LaunchLedger ledger,
    TextWriter log)
{
    private const string ChildScriptName = "Invoke-ShadowCoordinatorChild.ps1";

    private readonly CoordinatorRequest _request = request;
    private readonly CoordinatorState _state = state;
    private readonly byte[] _stateKey = stateKey;
    private readonly StageArtifactIndex _index = index;
    private readonly ChildToolInvoker _invoker = invoker;
    private readonly SlotSupervisor _supervisor = supervisor;
    private readonly LaunchLedger _ledger = ledger;
    private readonly TextWriter _log = log;

    private string _sealedSnapshotName = string.Empty;
    private string _sealedManifestPath = string.Empty;
    private string _sealedManifestDigest = string.Empty;
    private string _sealedSnapshotDigest = string.Empty;
    private string _runSetPath = string.Empty;
    private readonly Dictionary<int, SlotPlan> _slotPlans = [];
    private ReconciliationPlan? _reconciliationPlan;
    private DeliveryPlan? _deliveryPlan;
    private CorpusStager? _stager;

    /// <summary>The two slots this coordinator declares, in the only order it runs them.</summary>
    private static readonly SlotStage Slot1Stage = new(
        1,
        CoordinatorRequest.FirstSlotName,
        PreparationState.Slot1Authorized,
        PreparationState.Slot1Launching,
        PreparationState.Slot1Running,
        PreparationState.Slot1TerminalObserved,
        PreparationState.Slot1TerminalVerified,
        PreparationState.Slot1TerminalFailed,
        PreparationState.Slot1TerminalTimedOut,
        "slot1Plan",
        "slot1Prelaunch",
        "slot1Run",
        "slot1Verify");

    private static readonly SlotStage Slot2Stage = new(
        2,
        CoordinatorRequest.SecondSlotName,
        PreparationState.Slot2Authorized,
        PreparationState.Slot2Launching,
        PreparationState.Slot2Running,
        PreparationState.Slot2TerminalObserved,
        PreparationState.Slot2TerminalVerified,
        PreparationState.Slot2TerminalFailed,
        PreparationState.Slot2TerminalTimedOut,
        "slot2Plan",
        "slot2Prelaunch",
        "slot2Run",
        "slot2Verify");

    private static readonly SlotStage[] Stages = [Slot1Stage, Slot2Stage];

    /// <summary>
    /// The file name the qualification path publishes its single-use launch
    /// authorization under, beside the declaration it authorizes.
    /// </summary>
    private const string PublishedLaunchTokenName = "launch-authorization.token";

    /// <summary>Runs until the target state is reached, halting early only when instructed to.</summary>
    /// <remarks>
    /// The walk stops of its own accord when a supervised slot records a terminal
    /// that is not 'complete'. That is not a judgement about the run: it is the
    /// reviewed set's own rule, which never runs a later slot after a failed or
    /// timed-out one and never reconciles a partial set. Stopping here rather
    /// than refusing at the next transition is what lets the audit be written and
    /// the ending reported, instead of burying the outcome under a contract
    /// error about a precondition the run was never going to meet.
    /// </remarks>
    internal void Run(PreparationState target, PreparationState? haltAfter)
    {
        // The audit is written on entry, after every commit, and on every way out
        // of this method - including the ones that are faults. An audit that is
        // only written when a run ends well is an audit that is missing exactly
        // when it is wanted, and a resumed run would read a record describing a
        // state the coordinator has already left.
        WriteOpeningAudit();
        var targetRank = PreparationStateNames.RankOf(target);
        var haltRank = haltAfter is { } halt ? PreparationStateNames.RankOf(halt) : -1;
        try
        {
            // Asked once, before anything is attempted, and asked of the whole
            // root rather than of the steps this run happens to reach. A resumed
            // run whose remaining ranks are already committed launches nothing,
            // so a per-step gate would never see an open intent left by an
            // earlier run - and this run would complete and publish an audit
            // whose own census says a launch was never accounted for.
            _ledger.RequireNothingUnaccounted();
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
                if (PreparationStateNames.IsUnsuccessfulTerminal(committed))
                {
                    _log.WriteLine(
                        $"stop after {PreparationStateNames.ToName(committed)} (correlationId={_request.CorrelationId}): " +
                        "a set never advances past a slot that did not complete.");
                    WriteAuditForFault(
                        AuditReasonStoppedNotComplete,
                        $"the set stopped at '{PreparationStateNames.ToName(committed)}' because a slot did not complete");
                    return;
                }
            }
        }
        catch (DeliberateHaltException halted)
        {
            WriteAuditForFault(AuditReasonDeliberateHalt, $"the run was halted after '{PreparationStateNames.ToName(halted.State)}'");
            throw;
        }
        catch (UnresolvedLaunchException error)
        {
            WriteAuditForFault(AuditReasonUnresolvedLaunch, error.Message);
            throw;
        }
        catch (ContractException error)
        {
            WriteAuditForFault(AuditReasonContractRefusal, error.Message);
            throw;
        }
        catch (ChildFailureException error)
        {
            WriteAuditForFault(AuditReasonChildFailure, error.Message);
            throw;
        }
        catch (Exception error)
        {
            // Deliberately broad, and deliberately rethrowing. The audit is the
            // only durable account of what this run touched, so it is written even
            // for a fault this class did not anticipate - and then the fault is
            // allowed to travel, because swallowing it here would turn an
            // unexplained crash into a silent success.
            WriteAuditForFault(AuditReasonUnexpectedFault, error.Message);
            throw;
        }
        WriteAuditSafely(AuditReasonCompleted, "the run reached its target");
    }

    /// <summary>Performs, or recognises as already performed, the transition at one rank.</summary>
    private PreparationState Advance(int rank)
    {
        // Every launch this rank makes is bound to the transition that wanted it
        // before anything can start, so an intent found by a later run names the
        // step it belongs to rather than merely the process that ran it.
        _ledger.Binding = BindingForRank(rank);
        if (PreparationStateNames.RankOf(_state.State) >= rank)
        {
            var recorded = RecordedStateAtRank(rank);
            _log.WriteLine($"skip {PreparationStateNames.ToName(recorded)} (already recorded at sequence {SequenceOf(recorded)}, correlationId={_request.CorrelationId})");
            RehydrateFor(recorded);
            return recorded;
        }
        // A terminal rank is the one place where WHICH state gets committed is
        // not known before the work is done, because it is the supervised run's
        // own artifact that says whether the run completed, failed or timed out.
        if (SlotStageAtTerminalRank(rank) is { } terminalStage)
        {
            var (outcome, terminalEvidence, terminalDetail) = VerifySlotTerminal(terminalStage);
            _log.WriteLine($"enter {PreparationStateNames.ToName(outcome)} (correlationId={_request.CorrelationId})");
            CommitAndAudit(outcome, terminalEvidence, terminalDetail);
            return outcome;
        }

        // A running state is committed by its own transition, in the middle of
        // it rather than at the end: the identity of a child has to be durable
        // BEFORE the wait that may outlive this process.
        if (SlotStageAtRunningRank(rank) is { } runningStage)
        {
            _log.WriteLine($"enter {PreparationStateNames.ToName(runningStage.Running)} (correlationId={_request.CorrelationId})");
            RunSlot(runningStage);
            return runningStage.Running;
        }

        // The comparison is a supervised child too, and is committed the same way
        // and for the same reason.
        if (rank == PreparationStateNames.RankOf(PreparationState.ReconciliationRunning))
        {
            _log.WriteLine($"enter {PreparationStateNames.ToName(PreparationState.ReconciliationRunning)} (correlationId={_request.CorrelationId})");
            RunComparison();
            return PreparationState.ReconciliationRunning;
        }

        // And so is the delivery evaluation, which is a supervised child that
        // writes a decision to a file and to nowhere else.
        if (rank == PreparationStateNames.RankOf(PreparationState.DeliveryRunning))
        {
            _log.WriteLine($"enter {PreparationStateNames.ToName(PreparationState.DeliveryRunning)} (correlationId={_request.CorrelationId})");
            RunDelivery();
            return PreparationState.DeliveryRunning;
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
            PreparationState.Slot1Authorized => AuthorizeSlot(Slot1Stage),
            PreparationState.Slot1Launching => BeginSlotLaunch(Slot1Stage),
            PreparationState.Slot1TerminalObserved => ObserveSlotTerminal(Slot1Stage),
            PreparationState.Slot2Authorized => AuthorizeSlot(Slot2Stage),
            PreparationState.Slot2Launching => BeginSlotLaunch(Slot2Stage),
            PreparationState.Slot2TerminalObserved => ObserveSlotTerminal(Slot2Stage),
            PreparationState.ReconciliationAuthorized => AuthorizeReconciliation(),
            PreparationState.ReconciliationLaunching => BeginReconciliationLaunch(),
            PreparationState.ReconciliationTerminalObserved => ObserveReconciliationTerminal(),
            PreparationState.ReconciliationVerified => VerifyReconciliation(),
            PreparationState.DeliveryAuthorized => AuthorizeDelivery(),
            PreparationState.DeliveryLaunching => BeginDeliveryLaunch(),
            PreparationState.DeliveryTerminalObserved => ObserveDeliveryTerminal(),
            PreparationState.DeliveryTerminalVerified => VerifyDelivery(),
            _ => throw new ContractException($"'{PreparationStateNames.ToName(next)}' is not a transition this coordinator performs.")
        };
        _state.Commit(_request, _stateKey, next, evidence, detail);
        _log.WriteLine($"commit {PreparationStateNames.ToName(next)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} evidence={_state.EvidenceDigestOf(next)} detail={detail}");
        WriteAuditSafely(AuditReasonTransitionCommitted, $"committed '{PreparationStateNames.ToName(next)}'");
        return next;
    }

    /// <summary>Commits a transition and refreshes the audit behind it, in that order.</summary>
    /// <remarks>
    /// The order is the whole point. State is authoritative and the audit is a
    /// report of it, so the audit is never allowed to describe a transition that
    /// is not yet durable. The reverse - an audit that lags a commit - is the
    /// recoverable direction: the next run over the same root rewrites it from
    /// the state record without relaunching anything.
    /// </remarks>
    private void CommitAndAudit(PreparationState next, MapNode evidence, string detail)
    {
        _state.Commit(_request, _stateKey, next, evidence, detail);
        _log.WriteLine($"commit {PreparationStateNames.ToName(next)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} evidence={_state.EvidenceDigestOf(next)} detail={detail}");
        WriteAuditSafely(AuditReasonTransitionCommitted, $"committed '{PreparationStateNames.ToName(next)}'");
    }

    /// <summary>Names the transition, set and slot that a launch made at this rank belongs to.</summary>
    /// <remarks>
    /// The name is derived defensively because a terminal rank holds three
    /// sibling states and refuses to name one: this method runs for every rank,
    /// including those, and a binding is a label rather than a decision.
    /// </remarks>
    private LaunchBinding BindingForRank(int rank)
    {
        // Read from the durable record rather than from a field, so that a
        // resumed run binds its launches to the same set the first run did.
        var setId = _state.EvidenceFor(PreparationState.RunSetVerified)?.GetText("setId") ?? string.Empty;
        foreach (var stage in Stages)
        {
            if (rank == PreparationStateNames.RankOf(stage.Running))
            {
                var terminal = _slotPlans.TryGetValue(stage.Ordinal, out var plan) ? plan.SlotTerminalPath : string.Empty;
                return new LaunchBinding(PreparationStateNames.ToName(stage.Running), setId, stage.Name, terminal);
            }
            if (rank == PreparationStateNames.RankOf(stage.TerminalVerified))
            {
                var terminal = _slotPlans.TryGetValue(stage.Ordinal, out var plan) ? plan.SlotTerminalPath : string.Empty;
                return new LaunchBinding(PreparationStateNames.ToName(stage.TerminalVerified), setId, stage.Name, terminal);
            }
        }
        if (rank == PreparationStateNames.RankOf(PreparationState.ReconciliationRunning))
        {
            return new LaunchBinding(
                PreparationStateNames.ToName(PreparationState.ReconciliationRunning),
                setId,
                "reconciliation",
                _request.ReconciliationSummaryPath);
        }
        if (rank == PreparationStateNames.RankOf(PreparationState.DeliveryRunning))
        {
            return new LaunchBinding(
                PreparationStateNames.ToName(PreparationState.DeliveryRunning),
                setId,
                "delivery",
                _request.DeliverySummaryPath);
        }
        return new LaunchBinding(PreparationStateNames.ToName(PreparationStateNames.StateAtRank(rank)), setId, string.Empty, string.Empty);
    }

    private static SlotStage? SlotStageAtTerminalRank(int rank)
    {
        foreach (var stage in Stages)
        {
            if (PreparationStateNames.RankOf(stage.TerminalVerified) == rank)
            {
                return stage;
            }
        }
        return null;
    }

    private static SlotStage? SlotStageAtRunningRank(int rank)
    {
        foreach (var stage in Stages)
        {
            if (PreparationStateNames.RankOf(stage.Running) == rank)
            {
                return stage;
            }
        }
        return null;
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
                ReadSlotPlanResult(Slot1Stage);
                break;
            case PreparationState.Slot2Authorized:
                ReadSlotPlanResult(Slot2Stage);
                break;
            case PreparationState.ReconciliationAuthorized:
                ReadReconciliationPlanResult();
                break;
            case PreparationState.DeliveryAuthorized:
                ReadDeliveryPlanResult();
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
            "slotAttemptRecordCount",
            "preLaunchRunRootCount");

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
        var attemptRecords = StrictJson.RequireInt(outcome.Result, "slotAttemptRecordCount", label, 0, int.MaxValue);
        if (attemptRecords != 0)
        {
            throw new ContractException($"The preparation observed {attemptRecords.ToString(CultureInfo.InvariantCulture)} reviewer attempt record(s); this coordinator prepares a run set and launches nothing.");
        }
        // A model start needs a run directory to publish its evidence into, and
        // this counts those directories. Zero of them is a measurement that this
        // preparation started no model - not the same statement as "this code does
        // not start models", which no audit could check.
        var runRoots = StrictJson.RequireInt(outcome.Result, "preLaunchRunRootCount", label, 0, int.MaxValue);
        if (runRoots != 0)
        {
            throw new ContractException($"The preparation observed {runRoots.ToString(CultureInfo.InvariantCulture)} reviewer run director(ies) before any launch; a prepared run set has none.");
        }

        var evidence = new MapNode()
            .Set("launchTokenPresent", true)
            .Set("setId", reportedSetId)
            .Set("plannedRunCount", planned)
            .Set("slotAttemptCount", attempts)
            .Set("slotAttemptRecordCount", attemptRecords)
            .Set("preLaunchRunRootCount", runRoots)
            .Set("realModelStartCount", 0)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"plannedRunCount={planned.ToString(CultureInfo.InvariantCulture)} slotAttempts=0");
    }

    // -----------------------------------------------------------------------
    // slotNAuthorized / slotNLaunching / slotNRunning / slotNTerminalObserved
    // / slotNTerminal{Verified,Failed,TimedOut}, for each of the two declared
    // slots in turn.
    // -----------------------------------------------------------------------

    /// <summary>
    /// Establishes that this run may launch one named slot, and binds every
    /// identity the launch will be judged against.
    /// </summary>
    /// <remarks>
    /// Authorization is separated from launching because the launch consumes
    /// something that cannot be un-consumed: the PowerShell owner makes its
    /// attempt record with CreateNew before it starts any work, so there is
    /// exactly one chance. Everything that could refuse the launch is therefore
    /// checked and committed BEFORE any state exists that says a launch is due.
    ///
    /// The second slot is refused outright until this run's own signed record
    /// says the first one ended verified-complete. The reviewed predecessor gate
    /// makes the same demand of the artifacts on disk, and both are wanted: the
    /// reviewed gate is the authority over the run set, and this one is the
    /// authority over THIS coordinator, which must not be able to reach a
    /// second launch by any path its own record does not already justify.
    ///
    /// Nothing here judges the run. It reads a plan, compares identities, hashes
    /// a token, and refuses on mismatch.
    /// </remarks>
    private (MapNode Evidence, string Detail) AuthorizeSlot(SlotStage stage)
    {
        var authorization = _request.RequireSlot(stage.Ordinal);
        RequirePredecessorVerified(stage);

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

        var plan = ReadSlotPlan(stage, RequestSlotPlan(stage));

        if (!string.Equals(plan.SetId, verifiedSetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan is built for run set '{plan.SetId}' and this run verified '{verifiedSetId}'.");
        }
        if (!string.Equals(plan.SlotName, stage.Name, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan describes slot '{plan.SlotName}'; this transition supervises '{stage.Name}'.");
        }
        if (!string.Equals(plan.SlotName, authorization.Name, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan describes slot '{plan.SlotName}' and the request declared '{authorization.Name}' at this position.");
        }
        // The two file identities the request declared for this slot, checked
        // against the ones the reviewed plan actually placed. Without this a
        // request could declare two slots whose names differed while both bound
        // to one state directory or one terminal file, and the second run would
        // overwrite or adopt the first one's evidence.
        var plannedStateDirName = LeafNameOf(plan.SlotStateDir);
        if (!string.Equals(plannedStateDirName, authorization.StateDirName, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan places slot '{plan.SlotName}' state under '{plannedStateDirName}' and the request declared '{authorization.StateDirName}'.");
        }
        var plannedTerminalName = LeafNameOf(plan.SlotTerminalPath);
        if (!string.Equals(plannedTerminalName, authorization.TerminalName, StringComparison.Ordinal))
        {
            throw new ContractException($"The qualification plan names slot '{plan.SlotName}' terminal evidence '{plannedTerminalName}' and the request declared '{authorization.TerminalName}'.");
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
    private (MapNode Evidence, string Detail) BeginSlotLaunch(SlotStage stage)
    {
        var authorized = _state.EvidenceFor(stage.Authorized)
            ?? throw new ContractException("Nothing authorized a launch, so no launch is due.");
        var setId = authorized.GetText("setId") ?? throw new ContractException($"The {PreparationStateNames.ToName(stage.Authorized)} record carries no setId.");
        var planDigest = authorized.GetText("planDigest") ?? throw new ContractException($"The {PreparationStateNames.ToName(stage.Authorized)} record carries no plan digest.");
        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("slotName", stage.Name)
            .Set("launchDue", true);
        return (evidence, $"slot={stage.Name} planDigest={planDigest}");
    }

    /// <summary>
    /// Starts the supervised child, makes its identity durable, then watches it
    /// until it stops or a plan deadline says to stop watching.
    /// </summary>
    private void RunSlot(SlotStage stage)
    {
        var authorized = _state.EvidenceFor(stage.Authorized)
            ?? throw new ContractException("Nothing authorized a launch, so nothing may be run.");
        // Asked FIRST, before the plan probe and before anything is written for
        // the child. A step whose last launch is unaccounted for is refused at
        // the gate, so the refusal names the ambiguity rather than whatever the
        // probe happens to trip over on the way there.
        _ledger.RequireLaunchable(stage.RunStep);
        var authorizedDigest = authorized.GetText("planDigest") ?? throw new ContractException($"The {PreparationStateNames.ToName(stage.Authorized)} record carries no plan digest.");

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
        var probePath = Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + stage.PrelaunchStep + ".result.json");
        if (File.Exists(probePath))
        {
            File.Delete(probePath);
        }
        var plan = ReadSlotPlan(stage, RequestSlotPlan(stage, stage.PrelaunchStep));
        if (!string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The plan now digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }
        // Re-checked immediately before the irreversible step for the same reason
        // the attempt census is: a record that said slot1 was verified when slot2
        // was authorized has to still say so now.
        RequirePredecessorVerified(stage);

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
        // Minted HERE, by the coordinator, and handed DOWN. The adapter echoes it
        // and the run result is required to carry exactly this value back, so the
        // identity does not originate in anything the reviewed run can write. It
        // could not be taken from the child result: that result lands in the
        // exchange directory, which the reviewed run can compute, and its
        // validation checks only fields that are readable from the request sitting
        // beside it - so an identity minted below would be an identity the reviewed
        // run could substitute in the window between the adapter's write and this
        // coordinator's read.
        var runExecutionId = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        childRequest.Set("runExecutionId", runExecutionId);
        // Re-bound now that the plan is known, so the intent this launch commits
        // names the set, the slot and the terminal artifact it is supposed to
        // produce rather than only the transition it happened at.
        _ledger.Binding = new LaunchBinding(
            PreparationStateNames.ToName(stage.Running),
            plan.SetId,
            plan.SlotName,
            plan.SlotTerminalPath);
        // Asked again immediately before the hand-over: the probe above is a
        // child too, and a coordinator killed inside it must not find this step
        // launchable on the next run merely because the gate was passed earlier.
        _ledger.RequireLaunchable(stage.RunStep);
        var launch = _supervisor.Start(stage.RunStep, ChildScript(), childRequest);

        // Committed BEFORE the wait. This is the whole reason the supervisor is
        // two-phase: a coordinator killed during a slot that ran for an hour must
        // come back able to name the child it left behind, and a record written
        // after the wait would only ever describe runs that did not need it.
        var running = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("slotName", plan.SlotName)
            // Committed with the launch, before the wait, so a coordinator killed
            // mid-slot comes back knowing which execution it authorized rather
            // than learning it from whatever the child left behind.
            .Set("runExecutionId", runExecutionId)
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("child", launch.DescribeIdentity())
            .Set("supervisionStartedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        _state.Commit(_request, _stateKey, stage.Running, running, $"childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        _log.WriteLine($"commit {PreparationStateNames.ToName(stage.Running)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        WriteAuditSafely(AuditReasonTransitionCommitted, $"committed '{PreparationStateNames.ToName(stage.Running)}'");

        var observation = _supervisor.Await(launch, plan.Deadlines, plan.SlotStateDir);
        _log.WriteLine($"observed {stage.Name} child disposition={observation.Disposition} exitCode={observation.ExitCode.ToString(CultureInfo.InvariantCulture)}");
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
    private (MapNode Evidence, string Detail) ObserveSlotTerminal(SlotStage stage)
    {
        var running = _state.EvidenceFor(stage.Running)
            ?? throw new ContractException("No slot was recorded running, so there is nothing to observe.");
        if (!_slotPlans.ContainsKey(stage.Ordinal))
        {
            ReadSlotPlanResult(stage);
        }
        var plan = _slotPlans[stage.Ordinal];

        if (_observedRun is null || _observedLaunch is null)
        {
            (_observedLaunch, _observedRun) = ResumeSupervision(stage, running, plan);
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
            "planDigest",
            "runExecutionId");
        var label = $"'{stage.RunStep}' child result";
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
        // The identity this coordinator minted for this slot and committed with the
        // launch. The result is required to echo it exactly, so the reviewed run
        // gets no say in it: rewriting the result file - or the copy the adapter
        // leaves for its verify process - can only produce a refusal, never a
        // substitution. Read from the committed record rather than from the result
        // so that a resumed coordinator holds the same authority the launching one
        // did.
        var runExecutionId = running.GetText("runExecutionId")
            ?? throw new ContractException(
                "The slot running record carries no run execution identity. It was committed by a build that did not mint one, " +
                "and an execution this coordinator cannot name is not one it will summarise.");
        StrictJson.RequireLiteral(outcome.Result, "runExecutionId", runExecutionId, label);
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
            .Set("runExecutionId", runExecutionId)
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
    private (PreparationState Outcome, MapNode Evidence, string Detail) VerifySlotTerminal(SlotStage stage)
    {
        var observed = _state.EvidenceFor(stage.TerminalObserved)
            ?? throw new ContractException("No terminal evidence was observed, so there is nothing to verify.");
        if (!_slotPlans.ContainsKey(stage.Ordinal))
        {
            ReadSlotPlanResult(stage);
        }
        var plan = _slotPlans[stage.Ordinal];
        var observedTerminalSha = observed.GetText("terminalSha256")
            ?? throw new ContractException($"The {PreparationStateNames.ToName(stage.TerminalObserved)} record carries no terminal digest.");
        // Handed back to the verify step rather than left for it to find on disk.
        // A record committed before this fix carries no identity, and a verify
        // step with none refuses, so an interrupted run prepared by an older build
        // is resumed into a refusal instead of into the weaker witness.
        var observedRunExecutionId = observed.GetText("runExecutionId")
            ?? throw new ContractException(
                $"The {PreparationStateNames.ToName(stage.TerminalObserved)} record carries no run-execution identity. " +
                "The identity the reviewed run was told to adopt is committed with that transition, and a verification " +
                "that cannot name it would have to trust the copy the audited run can reach.");

        var childRequest = SlotChildRequest(plan.Authorization)
            .Set("expectedPlanDigest", plan.PlanDigest)
            .Set("expectedRunExecutionId", observedRunExecutionId)
            .Set("expectedSetId", plan.SetId);
        var outcome = _invoker.Invoke(
            stage.VerifyStep,
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
            "slotAttemptRecordCount",
            "realModelStartCount",
            "realModelStartsGeneralist",
            "realModelStartsSpecialist",
            "realModelStartsVerifier",
            "realModelStartCensusComplete",
            "realModelStartCensusExact",
            "realModelStartUnmeasuredAllowance",
            "realVerifierAssignmentCount",
            "realVerifierAssignmentsByModel",
            "realVerifierAssignmentCensusComplete",
            "realVerifierAssignmentUnmeasuredAllowance",
            "verifierProcessStartCount");
        var label = $"'{stage.VerifyStep}' child result";

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

        // Exactly as many attempt records as slots this run has launched, and no
        // more. A higher census means something launched a slot behind this
        // coordinator's back; a lower one means an attempt record this run made
        // has been removed.
        var attempts = StrictJson.RequireInt(outcome.Result, "slotAttemptCount", label, 0, int.MaxValue);
        if (attempts != stage.Ordinal)
        {
            throw new ContractException(
                $"The run set carries {attempts.ToString(CultureInfo.InvariantCulture)} slot attempt(s) after supervising '{stage.Name}'; " +
                $"exactly {stage.Ordinal.ToString(CultureInfo.InvariantCulture)} launch(es) can have been made by this point.");
        }
        // Observed, not asserted. This coordinator invokes no model, but the run
        // it supervised may have started several, and reporting the census it was
        // given is the only honest thing to do with it.
        //
        // Two different questions, kept apart because conflating them is the
        // defect this replaced. The attempt record count is how many REVIEWER
        // PROCESSES the run set launched - one per slot - and is a diagnostic. The
        // real model start count is how many MODEL SUBPROCESSES those reviewers
        // actually started, across every role and every attempt, and is the figure
        // a budget is spent in. A two-slot run that starts four models reports two
        // and four, and it is the four that a ceiling has to be measured against.
        var attemptRecords = StrictJson.RequireInt(outcome.Result, "slotAttemptRecordCount", label, 0, int.MaxValue);
        var realStarts = StrictJson.RequireInt(outcome.Result, "realModelStartCount", label, 0, int.MaxValue);
        var realGeneralist = StrictJson.RequireInt(outcome.Result, "realModelStartsGeneralist", label, 0, int.MaxValue);
        var realSpecialist = StrictJson.RequireInt(outcome.Result, "realModelStartsSpecialist", label, 0, int.MaxValue);
        var realVerifier = StrictJson.RequireInt(outcome.Result, "realModelStartsVerifier", label, 0, int.MaxValue);
        // The breakdown has to add up to the total it is a breakdown of. A
        // disagreement here is a census this build cannot publish, not one it
        // picks the more convenient half of.
        if (realGeneralist + realSpecialist + realVerifier != realStarts)
        {
            throw new ContractException(
                $"The slot reports {realStarts.ToString(CultureInfo.InvariantCulture)} real model start(s) and a role breakdown summing to " +
                $"{(realGeneralist + realSpecialist + realVerifier).ToString(CultureInfo.InvariantCulture)}. A census whose parts contradict its total is refused.");
        }
        // Completeness is about evidence, not about outcome. False means a role
        // this run was authorized to use published nothing to count, so the spend
        // is unknown rather than zero, and everything downstream must refuse to
        // treat it as measured.
        var censusComplete = StrictJson.RequireBool(outcome.Result, "realModelStartCensusComplete", label);
        // Exactness is about interruption. A run that ended complete published
        // every attempt record it was going to; a run that failed or timed out may
        // have spent more than it recorded, so its census is a floor.
        var censusExact = StrictJson.RequireBool(outcome.Result, "realModelStartCensusExact", label);
        // And the size of that gap, computed on the reviewed side against the
        // run's own sealed plan. It is deliberately not a constant here: an
        // interrupted cross-verification phase hides every launch it made rather
        // than one, because those launches are sealed together at the end of the
        // phase, and a flat allowance would under-count them without bound.
        var unmeasuredAllowance = StrictJson.RequireInt(
            outcome.Result, "realModelStartUnmeasuredAllowance", label, 0, 65536);
        if (censusExact && unmeasuredAllowance != 0)
        {
            throw new ContractException(
                $"The slot reports an exact census and an unmeasured allowance of {unmeasuredAllowance.ToString(CultureInfo.InvariantCulture)}. " +
                "A run that published everything it was going to publish has nothing left unaccounted, and the two statements contradict each other.");
        }

        // The assignment census, read on the same terms and kept in its own unit.
        // A cross-verifier ASSIGNMENT is one candidate paired with one required
        // reciprocal model; a verifier PROCESS may serve a whole cluster of them.
        // The first is what a cohort's verifier ceiling is spent in, the second is
        // a diagnostic, and this build refuses to let either stand in for the
        // other.
        var assignments = StrictJson.RequireInt(outcome.Result, "realVerifierAssignmentCount", label, 0, int.MaxValue);
        var assignmentsByModel = ReadVerifierAssignmentsByModel(outcome.Result, label, assignments);
        var assignmentCensusComplete = StrictJson.RequireBool(outcome.Result, "realVerifierAssignmentCensusComplete", label);
        var assignmentAllowance = StrictJson.RequireInt(
            outcome.Result, "realVerifierAssignmentUnmeasuredAllowance", label, 0, 65536);
        var verifierProcessStarts = StrictJson.RequireInt(outcome.Result, "verifierProcessStartCount", label, 0, int.MaxValue);
        // The one contradiction that is always a contradiction. Grouping and
        // retries make the two censuses differ in either direction, so equality is
        // never required; but a run cannot have started a verifier process without
        // an assignment for it to serve, and a build that reported so would be
        // reporting a phase whose evidence disagrees with itself.
        if (assignments == 0 && verifierProcessStarts > 0)
        {
            throw new ContractException(
                $"The slot reports {verifierProcessStarts.ToString(CultureInfo.InvariantCulture)} verifier process start(s) and no " +
                "verifier assignment at all. A launch serves assignments, so the two halves of that census contradict each other.");
        }
        // The same contradiction against the other witness, and the one that
        // matters most. The assignment census has exactly one source - the
        // phase's sealed preview - and the reviewed side's fault path seals that
        // preview with an EMPTY assignment list and returns normally. The model
        // start census survives that, because every verifier launch publishes its
        // own record as it returns. So a slot that started verifier models and
        // reports no assignment is a slot whose assignment evidence was lost,
        // and it is refused HERE, per slot, where both figures are for the same
        // run. Checked only on the entry's totals it would be vacuous: one slot
        // reporting forty would carry another reporting nothing.
        if (assignments == 0 && realVerifier > 0)
        {
            throw new ContractException(
                $"The slot reports {realVerifier.ToString(CultureInfo.InvariantCulture)} real model start(s) in the verifier role and no " +
                "verifier assignment at all. Those two censuses are taken over the same phase of the same run, so the assignments it " +
                "stood on were lost rather than never made, and this build refuses to publish the loss as a zero.");
        }
        // No ordering is required between the two censuses. Grouping pushes
        // launches below assignments within one pass, and a re-verification of
        // the same candidates pushes them above it across passes: identities are
        // content digests and dedupe, launch nonces are minted fresh and do not.
        // The one relationship that always holds is checked per sealed preview,
        // on the reviewed side, where both figures belong to a single pass.
        if (assignmentCensusComplete && censusExact && assignmentAllowance != 0)
        {
            throw new ContractException(
                $"The slot reports a complete assignment census on a run that ended cleanly and an unmeasured allowance of " +
                $"{assignmentAllowance.ToString(CultureInfo.InvariantCulture)}. Those two statements contradict each other.");
        }

        var status = StrictJson.RequireString(outcome.Result, "terminalStatus", label);
        var timedOut = StrictJson.RequireBool(outcome.Result, "terminalTimedOut", label);
        var exitCode = StrictJson.RequireInt(outcome.Result, "terminalExitCode", label, int.MinValue, int.MaxValue);
        var state = status switch
        {
            "complete" => stage.TerminalVerified,
            "failed" => stage.TerminalFailed,
            "timedOut" => stage.TerminalTimedOut,
            _ => throw new ContractException($"The terminal evidence reports status '{status}', which is not one of the three endings its contract allows.")
        };
        // The two statements the artifact makes about a timeout have to agree. A
        // 'complete' that also claims to have timed out is a corrupt record, and
        // picking whichever field suited would be inventing a reading.
        if (timedOut != (state == stage.TerminalTimedOut))
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
            .Set("slotAttemptRecordCount", attemptRecords)
            .Set("realModelStartCount", realStarts)
            .Set("realModelStartsGeneralist", realGeneralist)
            .Set("realModelStartsSpecialist", realSpecialist)
            .Set("realModelStartsVerifier", realVerifier)
            .Set("realModelStartCensusComplete", censusComplete)
            .Set("realModelStartCensusExact", censusExact)
            .Set("realModelStartUnmeasuredAllowance", unmeasuredAllowance)
            .Set("realVerifierAssignmentCount", assignments)
            .Set("realVerifierAssignmentsByModel", assignmentsByModel)
            .Set("realVerifierAssignmentCensusComplete", assignmentCensusComplete)
            .Set("realVerifierAssignmentUnmeasuredAllowance", assignmentAllowance)
            .Set("verifierProcessStartCount", verifierProcessStarts)
            .Set("childResultSha256", outcome.ResultSha256);
        return (state, evidence, $"terminalStatus={status} attempts={attempts.ToString(CultureInfo.InvariantCulture)} realModelStarts={realStarts.ToString(CultureInfo.InvariantCulture)} realVerifierAssignments={assignments.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Reads a slot's per-model assignment breakdown, refusing one that does not
    /// account for the total it is published beside.
    /// </summary>
    private static ListNode ReadVerifierAssignmentsByModel(JsonElement result, string label, int total)
    {
        if (!result.TryGetProperty("realVerifierAssignmentsByModel", out var byModel) || byModel.ValueKind != JsonValueKind.Array)
        {
            throw new ContractException($"The {label} carries no 'realVerifierAssignmentsByModel' array.");
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var carried = new ListNode();
        var sum = 0;
        var index = 0;
        foreach (var entry in byModel.EnumerateArray())
        {
            var entryLabel = $"{label} verifier assignment breakdown {index.ToString(CultureInfo.InvariantCulture)}";
            if (entry.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {entryLabel} is not an object.");
            }
            var model = StrictJson.RequireString(entry, "verifierModel", entryLabel);
            if (model.Length is 0 or > 128)
            {
                throw new ContractException($"The {entryLabel} names a verifier model of an unusable length.");
            }
            if (!seen.Add(model))
            {
                throw new ContractException($"The {label} breaks its verifier assignments down by a model it names twice, so the breakdown is ambiguous.");
            }
            var count = StrictJson.RequireInt(entry, "assignmentCount", entryLabel, 0, int.MaxValue);
            sum += count;
            carried.Add(new MapNode().Set("verifierModel", model).Set("assignmentCount", count));
            index++;
        }
        // The breakdown has to account for the total, or one of the two is being
        // read as the census and the other is decoration.
        if (sum != total)
        {
            throw new ContractException(
                $"The {label} reports {total.ToString(CultureInfo.InvariantCulture)} verifier assignment(s) and a per-model " +
                $"breakdown summing to {sum.ToString(CultureInfo.InvariantCulture)}, so its census does not account for itself.");
        }
        return carried;
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
    private (SlotLaunch Launch, SlotObservation Observation) ResumeSupervision(SlotStage stage, MapNode running, SlotPlan plan) =>
        ResumeSupervision(
            PreparationStateNames.ToName(stage.Running),
            stage.Name,
            stage.RunStep,
            running,
            plan.Deadlines,
            plan.SlotStateDir);

    /// <summary>
    /// Re-attaches to the child a running record names, rather than starting a
    /// second one.
    /// </summary>
    /// <remarks>
    /// Shared by the slots and by the reconciliation because the recovery is the
    /// same recovery: the record names a process id AND a start time, the
    /// supervisor adopts only that exact identity, and the wait resumes on the
    /// same plan budget the launch was made under.
    /// </remarks>
    private (SlotLaunch Launch, SlotObservation Observation) ResumeSupervision(
        string runningName,
        string label,
        string runStep,
        MapNode running,
        SlotDeadlines deadlines,
        string activityDirectory)
    {
        var child = running.Get("child") as MapNode
            ?? throw new ContractException($"The {runningName} record carries no child identity, so a resumed run cannot find what it left behind.");
        var processId = child.GetInteger("childProcessId")
            ?? throw new ContractException($"The {runningName} record carries no child process id.");
        var startedAt = child.GetText("childStartedAtUtc") is { Length: > 0 } recordedStart
            ? recordedStart
            : throw new ContractException($"The {runningName} record carries no child start time, so a recycled process id could be mistaken for the child.");
        var childRequestSha = child.GetText("childRequestSha256")
            ?? throw new ContractException($"The {runningName} record carries no child request digest.");

        var launch = _supervisor.Adopt(runStep, childRequestSha, (int)processId, startedAt);
        _log.WriteLine($"resume supervising recorded {label} child processId={processId.ToString(CultureInfo.InvariantCulture)} startedAtUtc={startedAt}");
        var observation = _supervisor.Await(launch, deadlines, activityDirectory);
        return (launch, observation);
    }

    /// <summary>
    /// Refuses a slot whose predecessor this run's own record does not show
    /// ending verified-complete.
    /// </summary>
    /// <remarks>
    /// The reviewed predecessor gate reads the artifacts and is the authority
    /// over the run set. This one reads the signed state and is the authority
    /// over the coordinator, and it exists because those are different
    /// questions: a coordinator that never supervised slot1 could still find a
    /// complete slot1 terminal on disk, put there by a hand-run, and would then
    /// report a two-slot set it had only half performed.
    /// </remarks>
    private void RequirePredecessorVerified(SlotStage stage)
    {
        if (stage.Ordinal <= 1)
        {
            return;
        }
        var predecessor = Stages[stage.Ordinal - 2];
        var predecessorRank = PreparationStateNames.RankOf(predecessor.TerminalVerified);
        PreparationState? recorded = null;
        foreach (var transition in _state.Transitions)
        {
            if (PreparationStateNames.RankOf(transition.State) == predecessorRank)
            {
                recorded = transition.State;
            }
        }
        if (recorded is null)
        {
            throw new ContractException(
                $"Slot '{stage.Name}' cannot be authorized before this run records a terminal for '{predecessor.Name}'. " +
                "The set advances one proven slot at a time.");
        }
        if (recorded != predecessor.TerminalVerified)
        {
            throw new ContractException(
                $"Slot '{stage.Name}' cannot be authorized: this run recorded '{PreparationStateNames.ToName(recorded.Value)}' for '{predecessor.Name}'. " +
                "A later slot never follows one that did not complete.");
        }
    }

    /// <summary>The last path component of a path, without touching the file system.</summary>
    private static string LeafNameOf(string path)
    {
        var trimmed = path.TrimEnd('/', '\\');
        var leaf = Path.GetFileName(trimmed);
        return leaf.Length > 0 ? leaf : trimmed;
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
            .Set("launchAuthorizationTokenPath", authorization.LaunchAuthorizationTokenPath)
            // Forwarded verbatim and never read. The strings are the reviewed
            // path's to interpret; what this coordinator does with them is put
            // them in the signed request, hand them over, and commit their
            // digest. Nothing here compares one to a literal, and there is no
            // branch anywhere in this program that could.
            .Set("bindSealedArguments", authorization.ModelPlan.BindSealedArguments)
            .Set("opaqueSlotArguments", authorization.ModelPlan.AsList());
    }

    private ChildOutcome RequestSlotPlan(SlotStage stage, string? step = null)
    {
        var authorization = _request.RequireSlot(stage.Ordinal);
        return _invoker.Invoke(
            step ?? stage.PlanStep,
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

    private SlotPlan ReadSlotPlan(SlotStage stage, ChildOutcome outcome)
    {
        var label = $"'{stage.PlanStep}' child result";
        var authorization = _request.RequireSlot(stage.Ordinal);
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
        _slotPlans[stage.Ordinal] = plan;
        return plan;
    }

    private void ReadSlotPlanResult(SlotStage stage)
    {
        var committed = _state.EvidenceFor(stage.Authorized);
        var label = $"'{stage.PlanStep}' child result";
        var result = ReadCommittedChildResult(stage.Authorized, stage.PlanStep, label);
        var plan = ReadSlotPlan(stage, new ChildOutcome(
            0,
            Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + stage.PlanStep + ".result.json"),
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
    private SlotObservation? _observedReconcileRun;
    private SlotLaunch? _observedReconcileLaunch;
    private SlotObservation? _observedDeliveryRun;
    private SlotLaunch? _observedDeliveryLaunch;

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
        .Set("reviewerScriptPath", _request.SlotReviewerScriptPath);

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

    private const string ReconciliationRequestContractVersion = "devpilot.shadow-run-coordinator.reconciliation-request.v1";

    private const string ReconciliationSummaryContractVersion = "devpilot.shadow-run-coordinator.reconciliation-summary.v1";

    private const string DeliveryRequestContractVersion = "devpilot.shadow-run-coordinator.delivery-request.v1";

    private const string DeliverySummaryContractVersion = "devpilot.shadow-run-coordinator.delivery-summary.v1";

    // -----------------------------------------------------------------------
    // reconciliationAuthorized / reconciliationLaunching
    // / reconciliationTerminalObserved / reconciliationVerified
    // -----------------------------------------------------------------------

    /// <summary>
    /// Establishes that the whole declared set may now be compared, and binds
    /// the comparison to the plan both slots ran under.
    /// </summary>
    /// <remarks>
    /// Two gates, deliberately not one. This coordinator's own record must show
    /// every declared slot ending verified-complete, and the reviewed readiness
    /// gate - which reads the immutable terminals, their binding to the sealed
    /// declaration, and whether any recorded child is still alive - must accept
    /// the set. Neither substitutes for the other: the first is what stops this
    /// program reaching a reconciliation it did not itself earn, and the second
    /// is what stops any program reconciling a set the artifacts do not support.
    ///
    /// Nothing here reads a finding. The comparison is the reviewed tool's, and
    /// what this transition binds is which set, which plan and which output
    /// directory it will run over.
    /// </remarks>
    private (MapNode Evidence, string Detail) AuthorizeReconciliation()
    {
        var reconciliation = _request.RequireSlotSet().Reconciliation.Require();
        RequireEverySlotVerified();

        var verified = _state.EvidenceFor(PreparationState.RunSetVerified)
            ?? throw new ContractException("The run holds no runSetVerified record, so there is no verified declaration to reconcile.");
        var verifiedSetId = verified.GetText("setId") ?? throw new ContractException("The runSetVerified record carries no setId.");

        var plan = ReadReconciliationPlan(RequestReconciliationPlan(ReconcilePlanStep));
        if (!string.Equals(plan.SetId, verifiedSetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The reconciliation is built for run set '{plan.SetId}' and this run verified '{verifiedSetId}'.");
        }
        // Every slot this run supervised must be the plan digest the
        // reconciliation is about to compare under, or the comparison would be
        // over runs from a different question.
        foreach (var stage in Stages)
        {
            var terminal = _state.EvidenceAtRank(PreparationStateNames.RankOf(stage.TerminalVerified))
                ?? throw new ContractException($"The run holds no terminal record for '{stage.Name}'.");
            var terminalDigest = terminal.GetText("planDigest")
                ?? throw new ContractException($"The terminal record for '{stage.Name}' carries no plan digest.");
            if (!string.Equals(terminalDigest, plan.PlanDigest, StringComparison.Ordinal))
            {
                throw new ContractException($"Slot '{stage.Name}' ran under plan {terminalDigest} and the reconciliation is built for {plan.PlanDigest}.");
            }
        }
        if (plan.RequiredRunCount != reconciliation.RequiredRunCount)
        {
            throw new ContractException(
                $"The reconciliation covers {plan.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the request authorized {reconciliation.RequiredRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        if (plan.RequiredRunCount != _request.PlannedRunCount)
        {
            throw new ContractException(
                $"The reconciliation covers {plan.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the declaration plans {_request.PlannedRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        if (plan.ArtifactCount != plan.RequiredRunCount)
        {
            throw new ContractException(
                $"The set offers {plan.ArtifactCount.ToString(CultureInfo.InvariantCulture)} run artifact(s) for a {plan.RequiredRunCount.ToString(CultureInfo.InvariantCulture)}-run comparison.");
        }
        // One shot, for the same reason a slot has one. The comparison writes a
        // stamped artifact every time it runs, so a second one would leave two
        // reports of the same set with no record of which this run stands on.
        if (plan.AttemptExists)
        {
            throw new ContractException(
                "The reconciliation already carries an attempt record, so its single authorization is spent. This coordinator does not reconcile a set twice.");
        }
        if (!string.Equals(plan.Head, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The reconciliation is built at toolkit head {plan.Head} and this request authorizes {_request.ToolkitHead}.");
        }
        var observedHead = GitHead.Resolve(_request.ToolkitRoot);
        if (!string.Equals(observedHead, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The toolkit is at head {observedHead} and this request authorizes {_request.ToolkitHead}.");
        }
        plan.Deadlines.RequireConsistent("reconciliation plan");

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("requiredRunCount", plan.RequiredRunCount)
            .Set("artifactCount", plan.ArtifactCount)
            .Set("outputDirectory", plan.OutputDirectory)
            .Set("head", plan.Head)
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("authorization", reconciliation.Describe())
            .Set("childResultSha256", plan.ChildResultSha256);
        return (evidence, $"setId={plan.SetId} runs={plan.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} planDigest={plan.PlanDigest}");
    }

    /// <summary>
    /// Publishes the strict versioned input the comparison will be run from, and
    /// records that a reconciliation is now due. It starts nothing.
    /// </summary>
    /// <remarks>
    /// The file is written here rather than at launch so that the bytes the
    /// child is asked to work from are on disk, and their digest is committed,
    /// before anything could have started. A crash between this state and the
    /// observation is then readable: the input exists, the attempt record says
    /// whether a comparison began, and nothing has to be guessed.
    /// </remarks>
    private (MapNode Evidence, string Detail) BeginReconciliationLaunch()
    {
        var authorized = _state.EvidenceFor(PreparationState.ReconciliationAuthorized)
            ?? throw new ContractException("Nothing authorized a reconciliation, so none is due.");
        var setId = authorized.GetText("setId") ?? throw new ContractException("The reconciliationAuthorized record carries no setId.");
        var planDigest = authorized.GetText("planDigest") ?? throw new ContractException("The reconciliationAuthorized record carries no plan digest.");
        var outputDirectory = authorized.GetText("outputDirectory") ?? throw new ContractException("The reconciliationAuthorized record carries no output directory.");
        var requiredRunCount = authorized.GetInteger("requiredRunCount")
            ?? throw new ContractException("The reconciliationAuthorized record carries no required run count.");

        Directory.CreateDirectory(_request.ReconciliationRoot);
        var input = new MapNode()
            .Set("contractVersion", ReconciliationRequestContractVersion)
            .Set("kind", "shadow-run-coordinator-reconciliation-request")
            .Set("correlationId", _request.CorrelationId)
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("requiredRunCount", requiredRunCount)
            .Set("outputDirectory", outputDirectory)
            .Set("summaryPath", _request.ReconciliationSummaryPath);
        CanonicalJson.WriteFileAtomic(_request.ReconciliationRequestPath, CanonicalJson.Readable(input));
        // Digested as the bytes that are on disk, because the bytes on disk are
        // what the reader will hash. A digest over a canonical rendering the
        // reader never sees would bind a document nobody is going to read.
        var inputSha = CanonicalJson.Sha256HexOfFile(_request.ReconciliationRequestPath);

        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("reconciliationRequestPath", _request.ReconciliationRequestPath)
            .Set("reconciliationRequestSha256", inputSha)
            .Set("summaryPath", _request.ReconciliationSummaryPath)
            .Set("reconciliationDue", true);
        return (evidence, $"reconciliationRequestSha256={inputSha}");
    }

    /// <summary>
    /// Runs the reviewed comparison once, under supervision, making the child's
    /// identity durable before the wait that may outlive this process.
    /// </summary>
    /// <remarks>
    /// The exit code is data. The reviewed tool is invoked without the switch
    /// that turns disagreement into a non-zero exit, because reacting to
    /// disagreement is precisely the judgement this coordinator must not make;
    /// what it requires instead is that the comparison ran and wrote its
    /// summary. A missing summary is refused as loudly as a hang.
    ///
    /// The comparison mints its attempt record before it starts, so a
    /// coordinator killed while it runs comes back to a spent authorization. The
    /// record committed here is what makes that recoverable rather than terminal:
    /// a resumed run finds the child it named and waits for THAT one, exactly as
    /// a slot does, instead of concluding that somebody else consumed the single
    /// attempt.
    /// </remarks>
    private void RunComparison()
    {
        var due = _state.EvidenceFor(PreparationState.ReconciliationLaunching)
            ?? throw new ContractException("No reconciliation was recorded due, so there is nothing to run.");
        // See RunSlot: asked before the probe, so an unaccounted-for previous
        // launch is refused at the gate rather than downstream of a child.
        _ledger.RequireLaunchable(ReconcileRunStep);
        var authorizedDigest = _state.EvidenceFor(PreparationState.ReconciliationAuthorized)?.GetText("planDigest")
            ?? throw new ContractException("The reconciliationAuthorized record carries no plan digest.");
        var inputSha = due.GetText("reconciliationRequestSha256")
            ?? throw new ContractException("The reconciliationLaunching record carries no input digest.");
        if (!File.Exists(_request.ReconciliationRequestPath))
        {
            throw new ContractException($"The reconciliation input at '{_request.ReconciliationRequestPath}' is gone.");
        }

        // Re-derived immediately before the irreversible step, and under its own
        // probe step name with any previous answer deleted, for the reason given
        // on the slot prelaunch probe: a resumed run must not read its own older
        // answer about whether a comparison has already been attempted.
        var probePath = Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + ReconcilePrelaunchStep + ".result.json");
        if (File.Exists(probePath))
        {
            File.Delete(probePath);
        }
        var plan = ReadReconciliationPlan(RequestReconciliationPlan(ReconcilePrelaunchStep));
        if (!string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The reconciliation plan now digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }
        RequireEverySlotVerified();
        if (plan.AttemptExists)
        {
            throw new ContractException(
                "The reconciliation acquired an attempt record between authorization and launch, so its single authorization has already been used.");
        }

        var childRequest = ReconciliationChildRequest()
            .Set("expectedPlanDigest", plan.PlanDigest)
            .Set("expectedSetId", plan.SetId)
            .Set("reconciliationRequestPath", _request.ReconciliationRequestPath)
            .Set("reconciliationRequestSha256", inputSha);
        // The comparison gets the same intent treatment as a slot, and for the
        // same reason: its authorization is single-use, so a relaunch this
        // coordinator cannot prove is safe must not happen.
        _ledger.Binding = new LaunchBinding(
            PreparationStateNames.ToName(PreparationState.ReconciliationRunning),
            plan.SetId,
            "reconciliation",
            _request.ReconciliationSummaryPath);
        _ledger.RequireLaunchable(ReconcileRunStep);
        var launch = _supervisor.Start(ReconcileRunStep, ChildScript(), childRequest);

        var running = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("child", launch.DescribeIdentity())
            .Set("supervisionStartedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        _state.Commit(_request, _stateKey, PreparationState.ReconciliationRunning, running, $"childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        _log.WriteLine($"commit {PreparationStateNames.ToName(PreparationState.ReconciliationRunning)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        WriteAuditSafely(AuditReasonTransitionCommitted, $"committed '{PreparationStateNames.ToName(PreparationState.ReconciliationRunning)}'");

        var observation = _supervisor.Await(launch, plan.Deadlines, plan.OutputDirectory);
        _log.WriteLine($"observed reconciliation child disposition={observation.Disposition} exitCode={observation.ExitCode.ToString(CultureInfo.InvariantCulture)}");
        _observedReconcileRun = observation;
        _observedReconcileLaunch = launch;
    }

    /// <summary>
    /// Reads what the supervised comparison left behind, without deciding what it
    /// means.
    /// </summary>
    private (MapNode Evidence, string Detail) ObserveReconciliationTerminal()
    {
        var running = _state.EvidenceFor(PreparationState.ReconciliationRunning)
            ?? throw new ContractException("No reconciliation was recorded running, so there is nothing to observe.");
        if (_reconciliationPlan is null)
        {
            ReadReconciliationPlanResult();
        }
        var plan = _reconciliationPlan
            ?? throw new ContractException("The reconciliation plan could not be recovered, so there is nothing to observe against.");

        if (_observedReconcileRun is null || _observedReconcileLaunch is null)
        {
            (_observedReconcileLaunch, _observedReconcileRun) = ResumeSupervision(
                PreparationStateNames.ToName(PreparationState.ReconciliationRunning),
                "reconciliation",
                ReconcileRunStep,
                running,
                plan.Deadlines,
                plan.OutputDirectory);
        }
        var launch = _observedReconcileLaunch!;
        var observation = _observedReconcileRun!;

        if (observation.Disposition is SlotObservation.HardDeadlineKill or SlotObservation.ActivityDeadlineKill)
        {
            throw new ChildFailureException(
                $"The reconciliation was stopped by this coordinator on a plan deadline ({observation.Disposition}) after " +
                $"{observation.ObservedSeconds.ToString(CultureInfo.InvariantCulture)} second(s).");
        }

        var outcome = _supervisor.ReadResult(
            launch,
            "summaryWritten",
            "summaryPath",
            "summarySha256",
            "comparisonExitCode",
            "setId",
            "planDigest",
            "reportPath",
            "reportSha256",
            "artifactPath",
            "artifactSha256");
        const string label = "'reconcileRun' child result";
        if (!StrictJson.RequireBool(outcome.Result, "summaryWritten", label))
        {
            throw new ContractException("The reconciliation produced no versioned summary, so there is nothing this coordinator may report about it.");
        }
        StrictJson.RequireLiteral(outcome.Result, "setId", plan.SetId, label);
        StrictJson.RequireLiteral(outcome.Result, "planDigest", plan.PlanDigest, label);
        var summaryPath = StrictJson.RequireString(outcome.Result, "summaryPath", label);
        if (!PathsAreSame(summaryPath, _request.ReconciliationSummaryPath))
        {
            throw new ContractException($"The reconciliation wrote its summary to '{summaryPath}' and this run asked for '{_request.ReconciliationSummaryPath}'.");
        }
        if (!File.Exists(summaryPath))
        {
            throw new ContractException($"The reconciliation reports a summary at '{summaryPath}', which does not exist.");
        }
        var reportedSummarySha = StrictJson.RequireHex(outcome.Result, "summarySha256", label, 64);
        var actualSummarySha = CanonicalJson.Sha256HexOfFile(summaryPath);
        if (!string.Equals(reportedSummarySha, actualSummarySha, StringComparison.Ordinal))
        {
            throw new ContractException($"The reconciliation summary digests to {actualSummarySha} and the child reported {reportedSummarySha}.");
        }
        // The two files the comparison produced are pinned HERE, where they were
        // just made, so the verification step reads the same bytes this step saw
        // rather than whatever stands at those paths later. Nothing is read out of
        // them; only the paths and their digests are carried.
        var reportPath = StrictJson.RequireString(outcome.Result, "reportPath", label);
        var artifactPath = StrictJson.RequireString(outcome.Result, "artifactPath", label);
        var reportSha = StrictJson.RequireHex(outcome.Result, "reportSha256", label, 64);
        var artifactSha = StrictJson.RequireHex(outcome.Result, "artifactSha256", label, 64);
        // Recorded, never acted upon. The reviewed tool is not asked to fail on
        // disagreement, so a non-zero here is a fault in the comparison rather
        // than a reading of the runs - and either way this coordinator only
        // reports the number.
        var comparisonExit = StrictJson.RequireInt(outcome.Result, "comparisonExitCode", label, int.MinValue, int.MaxValue);

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("summaryPath", summaryPath)
            .Set("summarySha256", actualSummarySha)
            .Set("reportPath", reportPath)
            .Set("reportSha256", reportSha)
            .Set("artifactPath", artifactPath)
            .Set("artifactSha256", artifactSha)
            .Set("comparisonExitCode", comparisonExit)
            .Set("supervision", observation.Describe())
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"disposition={observation.Disposition} comparisonExitCode={comparisonExit.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Has the reviewed reader parse the sealed comparison, and records its
    /// status, its digests and its census - and nothing else.
    /// </summary>
    /// <remarks>
    /// The counters arrive as an ordered list of name and value pairs and are
    /// copied across unread. That shape is the point: a map this program indexed
    /// by name would be a place for a rule about a particular count to grow, and
    /// there is no count whose meaning this coordinator is entitled to know. The
    /// status word and the outcome digest are the reviewed tool's own, checked
    /// here for structure and binding, never for plausibility.
    /// </remarks>
    private (MapNode Evidence, string Detail) VerifyReconciliation()
    {
        var observed = _state.EvidenceFor(PreparationState.ReconciliationTerminalObserved)
            ?? throw new ContractException("No reconciliation summary was observed, so there is nothing to verify.");
        var observedSummarySha = observed.GetText("summarySha256")
            ?? throw new ContractException("The reconciliationTerminalObserved record carries no summary digest.");
        var authorized = _state.EvidenceFor(PreparationState.ReconciliationAuthorized)
            ?? throw new ContractException("Nothing authorized a reconciliation, so there is nothing to verify.");
        var setId = authorized.GetText("setId") ?? throw new ContractException("The reconciliationAuthorized record carries no setId.");
        var planDigest = authorized.GetText("planDigest") ?? throw new ContractException("The reconciliationAuthorized record carries no plan digest.");

        var childRequest = ReconciliationChildRequest()
            .Set("expectedPlanDigest", planDigest)
            .Set("expectedSetId", setId)
            .Set("reconciliationRequestPath", _request.ReconciliationRequestPath)
            .Set("summaryPath", _request.ReconciliationSummaryPath);
        var outcome = _invoker.Invoke(
            ReconcileVerifyStep,
            ChildScript(),
            childRequest,
            "summarySha256",
            "reconciliationStatus",
            "reconciliationSha256",
            "reportPath",
            "reportSha256",
            "artifactPath",
            "artifactSha256",
            "artifactSignatureVerified",
            "artifactPromotable",
            "runCount",
            "requiredRunCount",
            "setId",
            "planDigest",
            "counts");
        const string label = "'reconcileVerify' child result";

        var verifiedSummarySha = StrictJson.RequireHex(outcome.Result, "summarySha256", label, 64);
        if (!string.Equals(verifiedSummarySha, observedSummarySha, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified reconciliation summary digests to {verifiedSummarySha} and this run observed {observedSummarySha}.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "artifactSignatureVerified", label))
        {
            throw new ContractException("The sealed comparison artifact did not verify under its key, so it stands on nothing.");
        }
        // A comparison that claimed to be promotable would be claiming to be
        // something this whole path is built never to produce.
        if (StrictJson.RequireBool(outcome.Result, "artifactPromotable", label))
        {
            throw new ContractException("The sealed comparison artifact claims to be promotable; an evaluation-only reconciliation never is.");
        }
        StrictJson.RequireLiteral(outcome.Result, "setId", setId, label);
        StrictJson.RequireLiteral(outcome.Result, "planDigest", planDigest, label);

        var requiredRunCount = StrictJson.RequireInt(outcome.Result, "requiredRunCount", label, 2, 16);
        var runCount = StrictJson.RequireInt(outcome.Result, "runCount", label, 0, 16);
        if (runCount != requiredRunCount)
        {
            throw new ContractException(
                $"The comparison covered {runCount.ToString(CultureInfo.InvariantCulture)} run(s) of a required {requiredRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        if (requiredRunCount != _request.PlannedRunCount)
        {
            throw new ContractException(
                $"The comparison requires {requiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the declaration plans {_request.PlannedRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }

        var status = StrictJson.RequireString(outcome.Result, "reconciliationStatus", label);
        var reconciliationSha = StrictJson.RequireHex(outcome.Result, "reconciliationSha256", label, 64);
        var reportPath = StrictJson.RequireString(outcome.Result, "reportPath", label);
        var reportSha = StrictJson.RequireHex(outcome.Result, "reportSha256", label, 64);
        var artifactPath = StrictJson.RequireString(outcome.Result, "artifactPath", label);
        var artifactSha = StrictJson.RequireHex(outcome.Result, "artifactSha256", label, 64);
        // The two files this run watched the comparison produce are the two files
        // that must have been read here. Without this the verification is over
        // whatever now stands at the paths a summary names, and a sealed artifact
        // that verifies under the same key but belongs to another set would be
        // reported as this set's result.
        RequireObservedFile(observed, "report", reportPath, reportSha);
        RequireObservedFile(observed, "artifact", artifactPath, artifactSha);
        var counts = ReadOpaqueCounts(outcome.Result, label);

        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("summarySha256", verifiedSummarySha)
            .Set("reconciliationStatus", status)
            .Set("reconciliationSha256", reconciliationSha)
            .Set("reportPath", reportPath)
            .Set("reportSha256", reportSha)
            .Set("artifactPath", artifactPath)
            .Set("artifactSha256", artifactSha)
            .Set("artifactSignatureVerified", true)
            .Set("promotable", false)
            .Set("runCount", runCount)
            .Set("requiredRunCount", requiredRunCount)
            .Set("counts", counts)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"reconciliationStatus={status} reconciliationSha256={reconciliationSha} runs={runCount.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Requires one of the comparison's two output files to be the same file, with
    /// the same bytes, that the observation committed.
    /// </summary>
    private static void RequireObservedFile(MapNode observed, string role, string path, string sha256)
    {
        var observedPath = observed.GetText(role + "Path")
            ?? throw new ContractException($"The reconciliationTerminalObserved record carries no {role} path.");
        var observedSha = observed.GetText(role + "Sha256")
            ?? throw new ContractException($"The reconciliationTerminalObserved record carries no {role} digest.");
        if (!PathsAreSame(path, observedPath))
        {
            throw new ContractException($"The verified comparison {role} is at '{path}' and this run observed '{observedPath}'.");
        }
        if (!string.Equals(sha256, observedSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified comparison {role} digests to {sha256} and this run observed {observedSha}.");
        }
    }

    /// <summary>
    /// Copies the comparison's census across without reading any of it.
    /// </summary>
    /// <remarks>
    /// The only things checked are that a name is a plain identifier and a value
    /// is a non-negative whole number, because a record has to be safe to print.
    /// No name is compared to a literal here or anywhere else in this program:
    /// the census is evidence to be carried, not a set of variables to reason
    /// over.
    /// </remarks>
    private static ListNode ReadOpaqueCounts(JsonElement result, string label)
    {
        if (!result.TryGetProperty("counts", out var counts) || counts.ValueKind != JsonValueKind.Array)
        {
            throw new ContractException($"The {label} carries no 'counts' array.");
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var carried = new ListNode();
        var index = 0;
        foreach (var entry in counts.EnumerateArray())
        {
            var entryLabel = $"{label} count {index.ToString(CultureInfo.InvariantCulture)}";
            if (entry.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {entryLabel} is not an object.");
            }
            var name = StrictJson.RequireString(entry, "name", entryLabel);
            if (name.Length is 0 or > 64 || !name.All(character => char.IsAsciiLetterOrDigit(character)))
            {
                throw new ContractException($"The {entryLabel} is named '{name}', which is not a plain identifier.");
            }
            if (!seen.Add(name))
            {
                throw new ContractException($"The {label} names '{name}' twice, so its census is ambiguous.");
            }
            var value = StrictJson.RequireInt(entry, "value", entryLabel, 0, int.MaxValue);
            carried.Add(new MapNode().Set("name", name).Set("value", value));
            index++;
        }
        if (index == 0)
        {
            throw new ContractException($"The {label} carries an empty census, so the comparison reported nothing countable.");
        }
        return carried;
    }

    /// <summary>Refuses a reconciliation this run's own record does not support.</summary>
    private void RequireEverySlotVerified()
    {
        foreach (var stage in Stages)
        {
            var rank = PreparationStateNames.RankOf(stage.TerminalVerified);
            PreparationState? recorded = null;
            foreach (var transition in _state.Transitions)
            {
                if (PreparationStateNames.RankOf(transition.State) == rank)
                {
                    recorded = transition.State;
                }
            }
            if (recorded is null)
            {
                throw new ContractException(
                    $"The reconciliation covers every declared slot and this run recorded no terminal for '{stage.Name}'. A partial set is never reconciled.");
            }
            if (recorded != stage.TerminalVerified)
            {
                throw new ContractException(
                    $"The reconciliation covers every declared slot and this run recorded '{PreparationStateNames.ToName(recorded.Value)}' for '{stage.Name}'. A failed set is never reconciled.");
            }
        }
    }

    private MapNode ReconciliationChildRequest()
    {
        var reconciliation = _request.RequireSlotSet().Reconciliation.Require();
        if (_sealedSnapshotName.Length == 0)
        {
            ReadSealResult();
        }
        return QualificationRequest()
            .Set("snapshotName", _sealedSnapshotName)
            .Set("manifestDigest", _sealedSnapshotDigest)
            .Set("launchAuthorizationTokenPath", reconciliation.LaunchAuthorizationTokenPath)
            .Set("reconciliationOutputDirectory", reconciliation.OutputDirectory)
            .Set("requiredRunCount", reconciliation.RequiredRunCount);
    }

    private ChildOutcome RequestReconciliationPlan(string step) => _invoker.Invoke(
        step,
        ChildScript(),
        ReconciliationChildRequest(),
        "setId",
        "planDigest",
        "requiredRunCount",
        "artifactCount",
        "outputDirectory",
        "reconciliationAttemptExists",
        "reconciliationReady",
        "slotTimeoutSeconds",
        "progressTimeoutSeconds",
        "perCallTimeoutSeconds",
        "head",
        "requiredRef",
        "headClean");

    private ReconciliationPlan ReadReconciliationPlan(ChildOutcome outcome)
    {
        const string label = "'reconcilePlan' child result";
        var reconciliation = _request.RequireSlotSet().Reconciliation.Require();
        if (!StrictJson.RequireBool(outcome.Result, "reconciliationReady", label))
        {
            throw new ContractException("The reviewed readiness gate does not accept this set for reconciliation.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "headClean", label))
        {
            throw new ContractException("The toolkit working tree is not clean, so the head a comparison would be attributed to is not the head that would run.");
        }
        StrictJson.RequireLiteral(outcome.Result, "requiredRef", _request.RequiredRef, label);
        var outputDirectory = StrictJson.RequireString(outcome.Result, "outputDirectory", label);
        if (!PathsAreSame(outputDirectory, reconciliation.OutputDirectory))
        {
            throw new ContractException($"The reconciliation would write to '{outputDirectory}' and the request authorized '{reconciliation.OutputDirectory}'.");
        }
        var plan = new ReconciliationPlan(
            StrictJson.RequireString(outcome.Result, "setId", label),
            StrictJson.RequireHex(outcome.Result, "planDigest", label, 64),
            StrictJson.RequireInt(outcome.Result, "requiredRunCount", label, 2, 16),
            StrictJson.RequireInt(outcome.Result, "artifactCount", label, 0, 16),
            outputDirectory,
            StrictJson.RequireBool(outcome.Result, "reconciliationAttemptExists", label),
            StrictJson.RequireString(outcome.Result, "head", label),
            new SlotDeadlines(
                StrictJson.RequireInt(outcome.Result, "slotTimeoutSeconds", label, 1, 14400),
                StrictJson.RequireInt(outcome.Result, "progressTimeoutSeconds", label, 0, 14400),
                StrictJson.RequireInt(outcome.Result, "perCallTimeoutSeconds", label, 1, 14400),
                reconciliation.SupervisionGraceSeconds),
            outcome.ResultSha256);
        _reconciliationPlan = plan;
        return plan;
    }

    private void ReadReconciliationPlanResult()
    {
        var committed = _state.EvidenceFor(PreparationState.ReconciliationAuthorized);
        var result = ReadCommittedChildResult(PreparationState.ReconciliationAuthorized, ReconcilePlanStep, "'reconcilePlan' child result");
        var plan = ReadReconciliationPlan(new ChildOutcome(
            0,
            Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + ReconcilePlanStep + ".result.json"),
            result,
            committed?.GetText("childResultSha256") ?? string.Empty));
        var authorizedDigest = committed?.GetText("planDigest");
        if (authorizedDigest is not null && !string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The resumed reconciliation plan digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }
    }

    private const string ReconcilePlanStep = "reconcilePlan";
    private const string ReconcilePrelaunchStep = "reconcilePrelaunch";
    private const string ReconcileRunStep = "reconcileRun";
    private const string ReconcileVerifyStep = "reconcileVerify";

    // -----------------------------------------------------------------------
    // deliveryAuthorized / deliveryLaunching / deliveryRunning
    // / deliveryTerminalObserved / deliveryTerminalVerified
    // -----------------------------------------------------------------------

    /// <summary>
    /// Establishes that a preview-only delivery decision may now be evaluated over
    /// a set this run both completed and compared, and refuses before any child if
    /// any write capability is anywhere in reach.
    /// </summary>
    /// <remarks>
    /// Three gates, deliberately not one. Every declared slot must end
    /// verified-complete in this run's own record; the reconciliation must be
    /// recorded verified in that same record; and the reviewed evaluation's own
    /// readiness answer must accept the set. A delivery over a set that was never
    /// compared would be a decision about runs nobody had reconciled.
    ///
    /// The capability check is the reason this transition exists at all rather
    /// than the launch simply happening. The reviewed side reports, as plain
    /// booleans and integers, whether any comment, vote or gate capability is
    /// currently requested and what it would be permitted to write. Every one of
    /// them must be off and zero HERE, before the evaluation child is started, so
    /// that a write-capable configuration or policy is a refusal rather than
    /// something discovered afterwards in a summary.
    ///
    /// Nothing here reads a finding. What this transition binds is which set,
    /// which plan, which reconciliation, which head and which correlation the
    /// decision will be evaluated under.
    /// </remarks>
    private (MapNode Evidence, string Detail) AuthorizeDelivery()
    {
        var delivery = _request.RequireSlotSet().RequireDelivery();
        RequireEverySlotVerified();
        var reconciled = _state.EvidenceFor(PreparationState.ReconciliationVerified)
            ?? throw new ContractException(
                "This run holds no reconciliationVerified record, so there is no compared set to evaluate a delivery decision over. " +
                "A delivery never runs ahead of the comparison that closes the set.");
        var reconciliationSha = reconciled.GetText("reconciliationSha256")
            ?? throw new ContractException("The reconciliationVerified record carries no outcome digest.");
        var reconciliationSummarySha = reconciled.GetText("summarySha256")
            ?? throw new ContractException("The reconciliationVerified record carries no summary digest.");
        var reconciliationArtifactPath = reconciled.GetText("artifactPath")
            ?? throw new ContractException("The reconciliationVerified record carries no artifact path.");
        var reconciliationArtifactSha = reconciled.GetText("artifactSha256")
            ?? throw new ContractException("The reconciliationVerified record carries no artifact digest.");

        var verified = _state.EvidenceFor(PreparationState.RunSetVerified)
            ?? throw new ContractException("The run holds no runSetVerified record, so there is no verified declaration to deliver over.");
        var verifiedSetId = verified.GetText("setId") ?? throw new ContractException("The runSetVerified record carries no setId.");

        var plan = ReadDeliveryPlan(RequestDeliveryPlan(DeliveryPlanStep));
        if (!string.Equals(plan.SetId, verifiedSetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery is built for run set '{plan.SetId}' and this run verified '{verifiedSetId}'.");
        }
        var reconciledSetId = reconciled.GetText("setId");
        if (reconciledSetId is not null && !string.Equals(plan.SetId, reconciledSetId, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery is built for run set '{plan.SetId}' and this run reconciled '{reconciledSetId}'.");
        }
        var reconciledPlanDigest = reconciled.GetText("planDigest");
        if (reconciledPlanDigest is not null && !string.Equals(plan.PlanDigest, reconciledPlanDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery is built for plan {plan.PlanDigest} and the reconciliation was verified under {reconciledPlanDigest}.");
        }
        foreach (var stage in Stages)
        {
            var terminal = _state.EvidenceAtRank(PreparationStateNames.RankOf(stage.TerminalVerified))
                ?? throw new ContractException($"The run holds no terminal record for '{stage.Name}'.");
            var terminalDigest = terminal.GetText("planDigest")
                ?? throw new ContractException($"The terminal record for '{stage.Name}' carries no plan digest.");
            if (!string.Equals(terminalDigest, plan.PlanDigest, StringComparison.Ordinal))
            {
                throw new ContractException($"Slot '{stage.Name}' ran under plan {terminalDigest} and the delivery is built for {plan.PlanDigest}.");
            }
        }
        if (plan.RequiredRunCount != delivery.RequiredRunCount)
        {
            throw new ContractException(
                $"The delivery covers {plan.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the request authorized {delivery.RequiredRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        if (plan.RequiredRunCount != _request.PlannedRunCount)
        {
            throw new ContractException(
                $"The delivery covers {plan.RequiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the declaration plans {_request.PlannedRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        // The reconciliation this decision closes over is the one this run
        // verified, byte for byte. Without this the delivery could be evaluated
        // against a comparison that merely happens to be at the same path.
        if (!string.Equals(plan.ReconciliationSha256, reconciliationSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery binds reconciliation {plan.ReconciliationSha256} and this run verified {reconciliationSha}.");
        }
        if (!PathsAreSame(plan.ReconciliationArtifactPath, reconciliationArtifactPath))
        {
            throw new ContractException($"The delivery reads its comparison from '{plan.ReconciliationArtifactPath}' and this run verified '{reconciliationArtifactPath}'.");
        }
        if (!string.Equals(plan.ReconciliationArtifactSha256, reconciliationArtifactSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The comparison at '{reconciliationArtifactPath}' now digests to {plan.ReconciliationArtifactSha256} and this run verified {reconciliationArtifactSha}.");
        }
        // One shot, for the same reason a comparison has one. The evaluation
        // seals a stamped decision every time it runs.
        if (plan.AttemptExists)
        {
            throw new ContractException(
                "The delivery already carries an attempt record, so its single authorization is spent. This coordinator does not evaluate a set twice.");
        }
        if (!string.Equals(plan.Head, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery is built at toolkit head {plan.Head} and this request authorizes {_request.ToolkitHead}.");
        }
        var observedHead = GitHead.Resolve(_request.ToolkitRoot);
        if (!string.Equals(observedHead, _request.ToolkitHead, StringComparison.Ordinal))
        {
            throw new ContractException($"The toolkit is at head {observedHead} and this request authorizes {_request.ToolkitHead}.");
        }
        plan.Deadlines.RequireConsistent("delivery plan");
        RequireNoWriteCapability(plan.Capability, "the delivery plan");

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("requiredRunCount", plan.RequiredRunCount)
            .Set("outputDirectory", plan.OutputDirectory)
            .Set("head", plan.Head)
            .Set("reconciliationSha256", plan.ReconciliationSha256)
            .Set("reconciliationSummarySha256", reconciliationSummarySha)
            .Set("reconciliationArtifactPath", plan.ReconciliationArtifactPath)
            .Set("reconciliationArtifactSha256", plan.ReconciliationArtifactSha256)
            .Set("configSha256", plan.ConfigSha256)
            .Set("policySha256", plan.PolicySha256)
            .Set("capability", plan.Capability.Describe())
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("authorization", delivery.Describe())
            .Set("childResultSha256", plan.ChildResultSha256);
        return (evidence, $"setId={plan.SetId} authorizationKind={plan.Capability.AuthorizationKind} planDigest={plan.PlanDigest}");
    }

    /// <summary>
    /// Publishes the strict versioned input the delivery decision will be
    /// evaluated from, and records that one is now due. It starts nothing.
    /// </summary>
    private (MapNode Evidence, string Detail) BeginDeliveryLaunch()
    {
        var authorized = _state.EvidenceFor(PreparationState.DeliveryAuthorized)
            ?? throw new ContractException("Nothing authorized a delivery, so none is due.");
        var setId = authorized.GetText("setId") ?? throw new ContractException("The deliveryAuthorized record carries no setId.");
        var planDigest = authorized.GetText("planDigest") ?? throw new ContractException("The deliveryAuthorized record carries no plan digest.");
        var outputDirectory = authorized.GetText("outputDirectory") ?? throw new ContractException("The deliveryAuthorized record carries no output directory.");
        var requiredRunCount = authorized.GetInteger("requiredRunCount")
            ?? throw new ContractException("The deliveryAuthorized record carries no required run count.");
        var reconciliationSha = authorized.GetText("reconciliationSha256")
            ?? throw new ContractException("The deliveryAuthorized record carries no reconciliation digest.");
        var reconciliationArtifactSha = authorized.GetText("reconciliationArtifactSha256")
            ?? throw new ContractException("The deliveryAuthorized record carries no comparison artifact digest.");

        Directory.CreateDirectory(_request.DeliveryRoot);
        var input = new MapNode()
            .Set("contractVersion", DeliveryRequestContractVersion)
            .Set("kind", "shadow-run-coordinator-delivery-request")
            .Set("correlationId", _request.CorrelationId)
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("requiredRunCount", requiredRunCount)
            // Written into the file the child reads, so the authorization the
            // evaluation runs under is on disk and digested rather than implied
            // by which code path invoked it.
            .Set("authorizationKind", DeliveryAuthorization.PreviewOnlyKind)
            .Set("commentsEnabled", false)
            .Set("votesEnabled", false)
            .Set("gatesEnabled", false)
            .Set("providerWriteBudget", 0)
            .Set("reconciliationSha256", reconciliationSha)
            .Set("reconciliationArtifactSha256", reconciliationArtifactSha)
            .Set("outputDirectory", outputDirectory)
            .Set("summaryPath", _request.DeliverySummaryPath);
        CanonicalJson.WriteFileAtomic(_request.DeliveryRequestPath, CanonicalJson.Readable(input));
        var inputSha = CanonicalJson.Sha256HexOfFile(_request.DeliveryRequestPath);

        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("deliveryRequestPath", _request.DeliveryRequestPath)
            .Set("deliveryRequestSha256", inputSha)
            .Set("summaryPath", _request.DeliverySummaryPath)
            .Set("deliveryDue", true);
        return (evidence, $"deliveryRequestSha256={inputSha}");
    }

    /// <summary>
    /// Runs the reviewed delivery evaluation once, under supervision, in preview
    /// only, making the child's identity durable before the wait.
    /// </summary>
    /// <remarks>
    /// The exit code is data, for the reason it is data for the comparison: a
    /// coordinator that reacted to it would be reacting to a reading of the runs.
    /// What is required instead is that the evaluation ran, sealed its decision
    /// and wrote its summary.
    ///
    /// The capability answer is re-derived immediately before the irreversible
    /// step and refused again, because a policy edited between the authorization
    /// and the launch is a different world from the one the authorization was
    /// committed against.
    /// </remarks>
    private void RunDelivery()
    {
        var due = _state.EvidenceFor(PreparationState.DeliveryLaunching)
            ?? throw new ContractException("No delivery was recorded due, so there is nothing to run.");
        _ledger.RequireLaunchable(DeliveryRunStep);
        var authorized = _state.EvidenceFor(PreparationState.DeliveryAuthorized)
            ?? throw new ContractException("Nothing authorized a delivery, so there is nothing to run.");
        var authorizedDigest = authorized.GetText("planDigest")
            ?? throw new ContractException("The deliveryAuthorized record carries no plan digest.");
        var authorizedReconciliationSha = authorized.GetText("reconciliationSha256")
            ?? throw new ContractException("The deliveryAuthorized record carries no reconciliation digest.");
        var inputSha = due.GetText("deliveryRequestSha256")
            ?? throw new ContractException("The deliveryLaunching record carries no input digest.");
        if (!File.Exists(_request.DeliveryRequestPath))
        {
            throw new ContractException($"The delivery input at '{_request.DeliveryRequestPath}' is gone.");
        }

        var probePath = Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + DeliveryPrelaunchStep + ".result.json");
        if (File.Exists(probePath))
        {
            File.Delete(probePath);
        }
        var plan = ReadDeliveryPlan(RequestDeliveryPlan(DeliveryPrelaunchStep));
        if (!string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery plan now digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }
        if (!string.Equals(plan.ReconciliationSha256, authorizedReconciliationSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery now binds reconciliation {plan.ReconciliationSha256} and the authorization was committed against {authorizedReconciliationSha}.");
        }
        RequireEverySlotVerified();
        RequireNoWriteCapability(plan.Capability, "the delivery prelaunch probe");
        if (plan.AttemptExists)
        {
            throw new ContractException(
                "The delivery acquired an attempt record between authorization and launch, so its single authorization has already been used.");
        }

        var childRequest = DeliveryChildRequest()
            .Set("expectedPlanDigest", plan.PlanDigest)
            .Set("expectedSetId", plan.SetId)
            .Set("deliveryRequestPath", _request.DeliveryRequestPath)
            .Set("deliveryRequestSha256", inputSha);
        _ledger.Binding = new LaunchBinding(
            PreparationStateNames.ToName(PreparationState.DeliveryRunning),
            plan.SetId,
            "delivery",
            _request.DeliverySummaryPath);
        _ledger.RequireLaunchable(DeliveryRunStep);
        var launch = _supervisor.Start(DeliveryRunStep, ChildScript(), childRequest);

        var running = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("deadlines", plan.Deadlines.Describe())
            .Set("child", launch.DescribeIdentity())
            .Set("supervisionStartedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        _state.Commit(_request, _stateKey, PreparationState.DeliveryRunning, running, $"childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        _log.WriteLine($"commit {PreparationStateNames.ToName(PreparationState.DeliveryRunning)} sequence={_state.Sequence.ToString(CultureInfo.InvariantCulture)} childProcessId={launch.ProcessId.ToString(CultureInfo.InvariantCulture)}");
        WriteAuditSafely(AuditReasonTransitionCommitted, $"committed '{PreparationStateNames.ToName(PreparationState.DeliveryRunning)}'");

        var observation = _supervisor.Await(launch, plan.Deadlines, plan.OutputDirectory);
        _log.WriteLine($"observed delivery child disposition={observation.Disposition} exitCode={observation.ExitCode.ToString(CultureInfo.InvariantCulture)}");
        _observedDeliveryRun = observation;
        _observedDeliveryLaunch = launch;
    }

    /// <summary>
    /// Reads what the supervised evaluation left behind, without deciding what it
    /// means.
    /// </summary>
    private (MapNode Evidence, string Detail) ObserveDeliveryTerminal()
    {
        var running = _state.EvidenceFor(PreparationState.DeliveryRunning)
            ?? throw new ContractException("No delivery was recorded running, so there is nothing to observe.");
        if (_deliveryPlan is null)
        {
            ReadDeliveryPlanResult();
        }
        var plan = _deliveryPlan
            ?? throw new ContractException("The delivery plan could not be recovered, so there is nothing to observe against.");

        if (_observedDeliveryRun is null || _observedDeliveryLaunch is null)
        {
            (_observedDeliveryLaunch, _observedDeliveryRun) = ResumeSupervision(
                PreparationStateNames.ToName(PreparationState.DeliveryRunning),
                "delivery",
                DeliveryRunStep,
                running,
                plan.Deadlines,
                plan.OutputDirectory);
        }
        var launch = _observedDeliveryLaunch!;
        var observation = _observedDeliveryRun!;

        if (observation.Disposition is SlotObservation.HardDeadlineKill or SlotObservation.ActivityDeadlineKill)
        {
            throw new ChildFailureException(
                $"The delivery evaluation was stopped by this coordinator on a plan deadline ({observation.Disposition}) after " +
                $"{observation.ObservedSeconds.ToString(CultureInfo.InvariantCulture)} second(s).");
        }

        var outcome = _supervisor.ReadResult(
            launch,
            "summaryWritten",
            "summaryPath",
            "summarySha256",
            "evaluationExitCode",
            "setId",
            "planDigest",
            "decisionPath",
            "decisionSha256",
            "providerWriteCount",
            "writeToolInvocations");
        const string label = "'deliveryRun' child result";
        if (!StrictJson.RequireBool(outcome.Result, "summaryWritten", label))
        {
            throw new ContractException("The delivery produced no versioned summary, so there is nothing this coordinator may report about it.");
        }
        StrictJson.RequireLiteral(outcome.Result, "setId", plan.SetId, label);
        StrictJson.RequireLiteral(outcome.Result, "planDigest", plan.PlanDigest, label);
        var summaryPath = StrictJson.RequireString(outcome.Result, "summaryPath", label);
        if (!PathsAreSame(summaryPath, _request.DeliverySummaryPath))
        {
            throw new ContractException($"The delivery wrote its summary to '{summaryPath}' and this run asked for '{_request.DeliverySummaryPath}'.");
        }
        if (!File.Exists(summaryPath))
        {
            throw new ContractException($"The delivery reports a summary at '{summaryPath}', which does not exist.");
        }
        var reportedSummarySha = StrictJson.RequireHex(outcome.Result, "summarySha256", label, 64);
        var actualSummarySha = CanonicalJson.Sha256HexOfFile(summaryPath);
        if (!string.Equals(reportedSummarySha, actualSummarySha, StringComparison.Ordinal))
        {
            throw new ContractException($"The delivery summary digests to {actualSummarySha} and the child reported {reportedSummarySha}.");
        }
        var decisionPath = StrictJson.RequireString(outcome.Result, "decisionPath", label);
        var decisionSha = StrictJson.RequireHex(outcome.Result, "decisionSha256", label, 64);
        // Refused here as well as at verification, because this is the first
        // moment the numbers exist. A run that wrote somewhere must not reach a
        // second transition before it is stopped.
        RequireZeroWrites(outcome.Result, label);
        var evaluationExit = StrictJson.RequireInt(outcome.Result, "evaluationExitCode", label, int.MinValue, int.MaxValue);

        var evidence = new MapNode()
            .Set("setId", plan.SetId)
            .Set("planDigest", plan.PlanDigest)
            .Set("summaryPath", summaryPath)
            .Set("summarySha256", actualSummarySha)
            .Set("decisionPath", decisionPath)
            .Set("decisionSha256", decisionSha)
            .Set("evaluationExitCode", evaluationExit)
            .Set("providerWriteCount", 0)
            .Set("writeToolInvocations", 0)
            .Set("supervision", observation.Describe())
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"disposition={observation.Disposition} evaluationExitCode={evaluationExit.ToString(CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// Has the reviewed reader open the sealed decision, and records its status,
    /// its digests, its census and the fact that it wrote nowhere - and nothing
    /// else.
    /// </summary>
    /// <remarks>
    /// The status word is the reviewed evaluation's own. It is carried, printed
    /// and committed, and it is never compared to a literal: there is no branch in
    /// this program on what a decision concluded, which is why a decision that
    /// found nothing, one that let nothing through, one that would be eligible in
    /// preview, and one built over a run the comparison called unusable all travel
    /// the same code path and all end with the same zero counts.
    ///
    /// What IS compared to a literal is the shape of the authorization: the kind,
    /// the three capability flags and the two write counters. Those are not
    /// judgement, they are the claim that nothing happened.
    /// </remarks>
    private (MapNode Evidence, string Detail) VerifyDelivery()
    {
        var observed = _state.EvidenceFor(PreparationState.DeliveryTerminalObserved)
            ?? throw new ContractException("No delivery summary was observed, so there is nothing to verify.");
        var observedSummarySha = observed.GetText("summarySha256")
            ?? throw new ContractException("The deliveryTerminalObserved record carries no summary digest.");
        var authorized = _state.EvidenceFor(PreparationState.DeliveryAuthorized)
            ?? throw new ContractException("Nothing authorized a delivery, so there is nothing to verify.");
        var setId = authorized.GetText("setId") ?? throw new ContractException("The deliveryAuthorized record carries no setId.");
        var planDigest = authorized.GetText("planDigest") ?? throw new ContractException("The deliveryAuthorized record carries no plan digest.");
        var reconciliationSha = authorized.GetText("reconciliationSha256")
            ?? throw new ContractException("The deliveryAuthorized record carries no reconciliation digest.");

        var childRequest = DeliveryChildRequest()
            .Set("expectedPlanDigest", planDigest)
            .Set("expectedSetId", setId)
            .Set("deliveryRequestPath", _request.DeliveryRequestPath)
            .Set("summaryPath", _request.DeliverySummaryPath);
        var outcome = _invoker.Invoke(
            DeliveryVerifyStep,
            ChildScript(),
            childRequest,
            "summarySha256",
            "deliveryStatus",
            "decisionPath",
            "decisionSha256",
            "decisionSignatureVerified",
            "decisionPromotable",
            "authorizationKind",
            "commentsEnabled",
            "votesEnabled",
            "gatesEnabled",
            "providerWriteCount",
            "writeToolInvocations",
            "reconciliationSha256",
            "runCount",
            "requiredRunCount",
            "setId",
            "planDigest",
            "counts");
        const string label = "'deliveryVerify' child result";

        var verifiedSummarySha = StrictJson.RequireHex(outcome.Result, "summarySha256", label, 64);
        if (!string.Equals(verifiedSummarySha, observedSummarySha, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified delivery summary digests to {verifiedSummarySha} and this run observed {observedSummarySha}.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "decisionSignatureVerified", label))
        {
            throw new ContractException("The sealed delivery decision did not verify under its key, so it stands on nothing.");
        }
        if (StrictJson.RequireBool(outcome.Result, "decisionPromotable", label))
        {
            throw new ContractException("The sealed delivery decision claims to be promotable; a preview-only decision never is.");
        }
        StrictJson.RequireLiteral(outcome.Result, "authorizationKind", DeliveryAuthorization.PreviewOnlyKind, label);
        StrictJson.RequireLiteral(outcome.Result, "setId", setId, label);
        StrictJson.RequireLiteral(outcome.Result, "planDigest", planDigest, label);
        StrictJson.RequireLiteral(outcome.Result, "reconciliationSha256", reconciliationSha, label);
        RequireNoWriteCapability(DeliveryCapability.Read(outcome.Result, label, "decisionPromotable"), "the verified delivery decision");
        RequireZeroWrites(outcome.Result, label);

        var requiredRunCount = StrictJson.RequireInt(outcome.Result, "requiredRunCount", label, 2, 16);
        var runCount = StrictJson.RequireInt(outcome.Result, "runCount", label, 0, 16);
        if (runCount != requiredRunCount)
        {
            throw new ContractException(
                $"The delivery decision covered {runCount.ToString(CultureInfo.InvariantCulture)} run(s) of a required {requiredRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }
        if (requiredRunCount != _request.PlannedRunCount)
        {
            throw new ContractException(
                $"The delivery decision requires {requiredRunCount.ToString(CultureInfo.InvariantCulture)} run(s) and the declaration plans {_request.PlannedRunCount.ToString(CultureInfo.InvariantCulture)}.");
        }

        // Carried, never compared. See the remarks above.
        var status = StrictJson.RequireString(outcome.Result, "deliveryStatus", label);
        var decisionPath = StrictJson.RequireString(outcome.Result, "decisionPath", label);
        var decisionSha = StrictJson.RequireHex(outcome.Result, "decisionSha256", label, 64);
        RequireObservedDeliveryFile(observed, "decision", decisionPath, decisionSha);
        var counts = ReadOpaqueCounts(outcome.Result, label);

        var evidence = new MapNode()
            .Set("setId", setId)
            .Set("planDigest", planDigest)
            .Set("summarySha256", verifiedSummarySha)
            .Set("deliveryStatus", status)
            .Set("decisionPath", decisionPath)
            .Set("decisionSha256", decisionSha)
            .Set("decisionSignatureVerified", true)
            .Set("reconciliationSha256", reconciliationSha)
            .Set("authorizationKind", DeliveryAuthorization.PreviewOnlyKind)
            .Set("promotable", false)
            .Set("commentsEnabled", false)
            .Set("votesEnabled", false)
            .Set("gatesEnabled", false)
            .Set("providerWriteCount", 0)
            .Set("writeToolInvocations", 0)
            .Set("runCount", runCount)
            .Set("requiredRunCount", requiredRunCount)
            .Set("counts", counts)
            .Set("childResultSha256", outcome.ResultSha256);
        return (evidence, $"deliveryStatus={status} decisionSha256={decisionSha} providerWriteCount=0");
    }

    /// <summary>
    /// Requires the sealed decision this verification read to be the same file,
    /// with the same bytes, that the observation committed.
    /// </summary>
    private static void RequireObservedDeliveryFile(MapNode observed, string role, string path, string sha256)
    {
        var observedPath = observed.GetText(role + "Path")
            ?? throw new ContractException($"The deliveryTerminalObserved record carries no {role} path.");
        var observedSha = observed.GetText(role + "Sha256")
            ?? throw new ContractException($"The deliveryTerminalObserved record carries no {role} digest.");
        if (!PathsAreSame(path, observedPath))
        {
            throw new ContractException($"The verified delivery {role} is at '{path}' and this run observed '{observedPath}'.");
        }
        if (!string.Equals(sha256, observedSha, StringComparison.Ordinal))
        {
            throw new ContractException($"The verified delivery {role} digests to {sha256} and this run observed {observedSha}.");
        }
    }

    /// <summary>
    /// Refuses anything that reports a capability to write, wherever it is
    /// reported from.
    /// </summary>
    /// <remarks>
    /// One method rather than a check per call site, because the point is that
    /// there is exactly one definition of "may not write" and it is applied at
    /// authorization, at prelaunch and at verification. A build that wanted to
    /// permit a write would have to change this method, and this method is read
    /// by the architecture suite.
    /// </remarks>
    private static void RequireNoWriteCapability(DeliveryCapability capability, string source)
    {
        if (!string.Equals(capability.AuthorizationKind, DeliveryAuthorization.PreviewOnlyKind, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"{source} reports authorization kind '{capability.AuthorizationKind}'. " +
                $"This coordinator performs exactly one kind of delivery, '{DeliveryAuthorization.PreviewOnlyKind}'.");
        }
        if (capability.CommentsEnabled || capability.VotesEnabled || capability.GatesEnabled)
        {
            throw new ContractException(
                $"{source} reports a write capability in reach (comments={capability.CommentsEnabled.ToString(CultureInfo.InvariantCulture)}, " +
                $"votes={capability.VotesEnabled.ToString(CultureInfo.InvariantCulture)}, gates={capability.GatesEnabled.ToString(CultureInfo.InvariantCulture)}). " +
                "A delivery is refused before it starts when anything could write.");
        }
        if (capability.Promotable)
        {
            throw new ContractException($"{source} reports a promotable outcome; a preview-only delivery never produces one.");
        }
    }

    /// <summary>Refuses any reported write, from any step, at any point.</summary>
    private static void RequireZeroWrites(JsonElement result, string label)
    {
        var providerWrites = StrictJson.RequireInt(result, "providerWriteCount", label, 0, int.MaxValue);
        var writeTools = StrictJson.RequireInt(result, "writeToolInvocations", label, 0, int.MaxValue);
        if (providerWrites != 0 || writeTools != 0)
        {
            throw new ContractException(
                $"The {label} reports {providerWrites.ToString(CultureInfo.InvariantCulture)} provider write(s) and " +
                $"{writeTools.ToString(CultureInfo.InvariantCulture)} write tool invocation(s). This coordinator supervises no path that may write, " +
                "so a non-zero count is a fault in what it supervised rather than a result to record.");
        }
    }

    private MapNode DeliveryChildRequest()
    {
        var set = _request.RequireSlotSet();
        var delivery = set.RequireDelivery();
        var reconciliation = set.Reconciliation.Require();
        if (_sealedSnapshotName.Length == 0)
        {
            ReadSealResult();
        }
        return QualificationRequest()
            .Set("snapshotName", _sealedSnapshotName)
            .Set("manifestDigest", _sealedSnapshotDigest)
            .Set("launchAuthorizationTokenPath", delivery.LaunchAuthorizationTokenPath)
            .Set("reconciliationOutputDirectory", reconciliation.OutputDirectory)
            .Set("deliveryOutputDirectory", delivery.OutputDirectory)
            .Set("requiredRunCount", delivery.RequiredRunCount)
            // Asked for by name, so the evaluation cannot be invoked under any
            // other authorization even by a caller that built its own request.
            .Set("authorizationKind", DeliveryAuthorization.PreviewOnlyKind);
    }

    private ChildOutcome RequestDeliveryPlan(string step) => _invoker.Invoke(
        step,
        ChildScript(),
        DeliveryChildRequest(),
        "setId",
        "planDigest",
        "requiredRunCount",
        "outputDirectory",
        "deliveryAttemptExists",
        "deliveryReady",
        "authorizationKind",
        "commentsEnabled",
        "votesEnabled",
        "gatesEnabled",
        "promotable",
        "providerWriteCount",
        "writeToolInvocations",
        "reconciliationSha256",
        "reconciliationArtifactPath",
        "reconciliationArtifactSha256",
        "configSha256",
        "policySha256",
        "slotTimeoutSeconds",
        "progressTimeoutSeconds",
        "perCallTimeoutSeconds",
        "head",
        "requiredRef",
        "headClean");

    private DeliveryPlan ReadDeliveryPlan(ChildOutcome outcome)
    {
        const string label = "'deliveryPlan' child result";
        var delivery = _request.RequireSlotSet().RequireDelivery();
        if (!StrictJson.RequireBool(outcome.Result, "deliveryReady", label))
        {
            throw new ContractException("The reviewed readiness gate does not accept this set for a delivery decision.");
        }
        if (!StrictJson.RequireBool(outcome.Result, "headClean", label))
        {
            throw new ContractException("The toolkit working tree is not clean, so the head a decision would be attributed to is not the head that would run.");
        }
        StrictJson.RequireLiteral(outcome.Result, "requiredRef", _request.RequiredRef, label);
        var outputDirectory = StrictJson.RequireString(outcome.Result, "outputDirectory", label);
        if (!PathsAreSame(outputDirectory, delivery.OutputDirectory))
        {
            throw new ContractException($"The delivery would write to '{outputDirectory}' and the request authorized '{delivery.OutputDirectory}'.");
        }
        // Read before anything else about the plan is believed: a plan that
        // reports a write capability is refused whatever else it says.
        var capability = DeliveryCapability.Read(outcome.Result, label);
        RequireZeroWrites(outcome.Result, label);
        var plan = new DeliveryPlan(
            StrictJson.RequireString(outcome.Result, "setId", label),
            StrictJson.RequireHex(outcome.Result, "planDigest", label, 64),
            StrictJson.RequireInt(outcome.Result, "requiredRunCount", label, 2, 16),
            outputDirectory,
            StrictJson.RequireBool(outcome.Result, "deliveryAttemptExists", label),
            StrictJson.RequireString(outcome.Result, "head", label),
            StrictJson.RequireHex(outcome.Result, "reconciliationSha256", label, 64),
            StrictJson.RequireString(outcome.Result, "reconciliationArtifactPath", label),
            StrictJson.RequireHex(outcome.Result, "reconciliationArtifactSha256", label, 64),
            StrictJson.RequireHex(outcome.Result, "configSha256", label, 64),
            StrictJson.RequireHex(outcome.Result, "policySha256", label, 64),
            capability,
            new SlotDeadlines(
                StrictJson.RequireInt(outcome.Result, "slotTimeoutSeconds", label, 1, 14400),
                StrictJson.RequireInt(outcome.Result, "progressTimeoutSeconds", label, 0, 14400),
                StrictJson.RequireInt(outcome.Result, "perCallTimeoutSeconds", label, 1, 14400),
                delivery.SupervisionGraceSeconds),
            outcome.ResultSha256);
        _deliveryPlan = plan;
        return plan;
    }

    private void ReadDeliveryPlanResult()
    {
        var committed = _state.EvidenceFor(PreparationState.DeliveryAuthorized);
        var result = ReadCommittedChildResult(PreparationState.DeliveryAuthorized, DeliveryPlanStep, "'deliveryPlan' child result");
        var plan = ReadDeliveryPlan(new ChildOutcome(
            0,
            Path.Combine(_request.ExchangeRoot, _request.CorrelationId + "-" + DeliveryPlanStep + ".result.json"),
            result,
            committed?.GetText("childResultSha256") ?? string.Empty));
        var authorizedDigest = committed?.GetText("planDigest");
        if (authorizedDigest is not null && !string.Equals(plan.PlanDigest, authorizedDigest, StringComparison.Ordinal))
        {
            throw new ContractException($"The resumed delivery plan digests to {plan.PlanDigest} and the authorization was committed against {authorizedDigest}.");
        }
    }

    private const string DeliveryPlanStep = "deliveryPlan";
    private const string DeliveryPrelaunchStep = "deliveryPrelaunch";
    private const string DeliveryRunStep = "deliveryRun";
    private const string DeliveryVerifyStep = "deliveryVerify";

    /// <summary>The reasons an audit is written, which are the ways a run can be at rest.</summary>
    /// <remarks>
    /// A closed vocabulary rather than free text, because the point of the field
    /// is that a reader can tell an audit describing a finished run from one
    /// describing a run that stopped in the middle - and a message can say
    /// anything, including nothing.
    /// </remarks>
    private const string AuditReasonRunning = "running";
    private const string AuditReasonTransitionCommitted = "transitionCommitted";
    private const string AuditReasonCompleted = "completed";
    private const string AuditReasonStoppedNotComplete = "stoppedAtUnsuccessfulTerminal";
    private const string AuditReasonDeliberateHalt = "deliberateHalt";
    private const string AuditReasonContractRefusal = "contractRefusal";
    private const string AuditReasonChildFailure = "childFailure";
    private const string AuditReasonUnresolvedLaunch = "unresolvedLaunch";
    private const string AuditReasonUnexpectedFault = "unexpectedFault";

    /// <summary>
    /// Replaces whatever audit stands over this root with one that says the run
    /// is in progress, and refuses to start if it cannot.
    /// </summary>
    /// <remarks>
    /// Every other audit write may be absorbed, because by then the signed state
    /// record is authoritative and losing a derived report is not worth
    /// destroying work over. This one is different in both directions.
    ///
    /// Nothing has been attempted yet, so faulting here destroys nothing. And a
    /// resumed run finds a previous invocation's audit already standing here,
    /// which is an ENDING and says so. Absorb a failure to overwrite it and this
    /// invocation walks on beneath a document that claims a finished run and
    /// carries that run's smaller spend; kill this process at any point after,
    /// or let its later audit writes fail the same way, and a reader is handed a
    /// stale ending it cannot tell from a fresh one.
    ///
    /// So the stale copy is removed FIRST and the opening audit written second.
    /// A fault between the two leaves no audit at all, which every reader of
    /// this root already refuses; a fault is never allowed to leave the previous
    /// run's ending in place while this one runs.
    ///
    /// What is refused is precisely the hazard and no more. The danger is a
    /// readable FILE that an earlier invocation left behind, because that is the
    /// only thing a reader can mistake for this run's report. A path that holds
    /// nothing, or holds a directory, carries no earlier ending and can be read
    /// as none, so a write that fails there is absorbed exactly as every other
    /// audit write is - the run has done what the record says it did, and the
    /// next run over the root rebuilds the report from that record.
    ///
    /// The distinction is drawn with <see cref="File.GetAttributes(string)"/>
    /// and not <c>File.Exists</c>. <c>File.Exists</c> answers false for a path
    /// it was not allowed to look at, which is exactly the shape of the file
    /// this method must never walk underneath: a stale ending the process cannot
    /// read is still a stale ending a reader with other rights can. An answer
    /// that cannot be trusted is treated as the hazard.
    /// </remarks>
    private void WriteOpeningAudit()
    {
        if (ProbeAuditPathOrRefuse("before this run starts") is AuditPathKind.File)
        {
            try
            {
                File.Delete(_request.AuditPath);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new ContractException(
                    $"The audit at '{_request.AuditPath}' could not be replaced before this run starts: {error.Message}. " +
                    "An audit left over from an earlier run would describe this root as finished while this run walks it, " +
                    "so the run is refused rather than started underneath it.");
            }
        }

        try
        {
            WriteAudit(AuditReasonRunning, "the run is in progress");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (ProbeAuditPathOrRefuse("after the opening audit could not be written") is AuditPathKind.File)
            {
                throw new ContractException(
                    $"The opening audit at '{_request.AuditPath}' could not be written and a file stands there anyway: {error.Message}. " +
                    "A reader would take that file for this run's report, so the run is refused rather than started underneath it.");
            }
            _log.WriteLine(
                $"audit not written ({AuditReasonRunning}): {error.Message}. " +
                "No audit stands over this root, which every reader of it refuses, " +
                "and the next run over this root rewrites the audit from the record.");
        }
    }

    /// <summary>What, if anything, occupies the audit path.</summary>
    private enum AuditPathKind
    {
        /// <summary>Nothing is there, so no earlier ending can be read from it.</summary>
        Absent,

        /// <summary>A directory is there. No reader can parse it as an audit.</summary>
        Directory,

        /// <summary>A file is there, and a reader would take it for this run's report.</summary>
        File,
    }

    /// <summary>
    /// Answers what occupies the audit path, refusing the run rather than
    /// guessing when it cannot tell.
    /// </summary>
    private AuditPathKind ProbeAuditPathOrRefuse(string moment)
    {
        try
        {
            FileAttributes attributes = File.GetAttributes(_request.AuditPath);
            return attributes.HasFlag(FileAttributes.Directory) ? AuditPathKind.Directory : AuditPathKind.File;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return AuditPathKind.Absent;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new ContractException(
                $"The audit path '{_request.AuditPath}' could not be examined {moment}: {error.Message}. " +
                "An ending this process cannot look at is still an ending a reader can, " +
                "so the run is refused rather than started underneath a file it cannot rule out.");
        }
    }

    /// <summary>Writes the audit, and refuses to let a failure to write it end the run.</summary>
    /// <remarks>
    /// The asymmetry here is deliberate and is the whole reason this wrapper
    /// exists. The signed state record is authoritative; the audit is a report
    /// derived from it. If the report cannot be written - a full disk, a
    /// directory sitting where the file should be, a hostile permission - the run
    /// has still done what the state says it did, and turning that into a fault
    /// would destroy work over a document that the very next run rebuilds from
    /// the record without relaunching anything.
    ///
    /// Only the storage faults are absorbed. An exception from ASSEMBLING the
    /// audit would mean the state record itself does not say what this class
    /// thinks it says, and that is not a fault anybody should be able to write
    /// off as a bad disk.
    /// </remarks>
    private void WriteAuditSafely(string terminalReason, string terminalDetail)
    {
        try
        {
            WriteAudit(terminalReason, terminalDetail);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.WriteLine(
                $"audit not written ({terminalReason}): {error.Message}. " +
                "The state record is authoritative and the next run over this root rewrites the audit from it.");
        }
    }

    /// <summary>
    /// Writes the audit for a run that is already ending badly, absorbing
    /// everything.
    /// </summary>
    /// <remarks>
    /// The strict version above is right where the audit is the only thing that
    /// could fail: an assembly fault there means the state record does not say
    /// what this class thinks it says, and that must not be written off as a bad
    /// disk. It is wrong inside a catch block. An exception raised while
    /// REPORTING a fault would replace the fault being reported, so a child
    /// failure or an unresolved launch - each with an exit code an operator acts
    /// on - would surface as an unrelated crash. The original fault is the more
    /// important of the two, so the reporting failure is logged and dropped.
    /// </remarks>
    private void WriteAuditForFault(string terminalReason, string terminalDetail)
    {
        try
        {
            WriteAudit(terminalReason, terminalDetail);
        }
        catch (Exception error)
        {
            _log.WriteLine(
                $"audit not written ({terminalReason}): {error.Message}. " +
                "The fault that ended this run is reported instead, and the next run over this root rewrites the audit from the record.");
        }
    }

    /// <summary>
    /// Writes the audit from the durable state alone.
    /// </summary>
    /// <remarks>
    /// Built entirely from the signed state rather than from what this process
    /// happened to do, so a preparation killed and resumed eight times publishes
    /// exactly the audit an uninterrupted one would. An audit assembled from
    /// in-memory work would silently thin out on every restart, which is the
    /// opposite of what an audit is for.
    ///
    /// Called after every commit and on every way out of the walk, so the audit
    /// cannot lag the state by more than the moment between the two writes - and
    /// it lags in the recoverable direction, never the other way.
    /// </remarks>
    /// <summary>
    /// Whether the signed launch ledger holds an intent for a step that a child
    /// process may have been started under.
    /// </summary>
    /// <remarks>
    /// 'notStarted' is the one phase that proves no process exists: the ledger
    /// records it after a start that failed. Every other phase - including
    /// 'intended', which is the unknown case, and a record too damaged to verify,
    /// which the ledger reports as 'intended' - leaves open that a reviewer ran.
    /// Read that way on purpose: this feeds a budget, and the only safe direction
    /// for a budget is to say a launch happened.
    /// </remarks>
    private bool LedgerSawLaunch(string step)
    {
        foreach (var standing in _ledger.ReadAll())
        {
            if (!string.Equals(standing.Step, step, StringComparison.Ordinal))
            {
                continue;
            }
            if (!string.Equals(standing.Phase, LaunchLedger.PhaseNotStarted, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    private void WriteAudit(string terminalReason, string terminalDetail)
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
            .Set("contractVersion", "devpilot.shadow-run-coordinator.audit.v2")
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
                .Set("preparationAttemptRecordCount", readiness!.Get("slotAttemptRecordCount") ?? Node.Null())
                .Set("slotLaunchCount", readiness.Get("slotAttemptCount") ?? Node.Null());
        }
        // The supervised slice reports separately, and only for the slots that
        // actually happened. A preparation that never authorized a launch
        // publishes an empty list rather than zeroed slot fields that would read
        // like a slot that ran and did nothing.
        var slotRecords = new ListNode();
        var supervisedCount = 0;
        var realStartTotal = 0;
        var realStartGeneralist = 0;
        var realStartSpecialist = 0;
        var realStartVerifier = 0;
        var censusComplete = true;
        var unmeasuredAllowance = 0;
        var launchedSlots = 0;
        var assignmentTotal = 0;
        var assignmentCensusComplete = true;
        var assignmentAllowance = 0;
        var verifierProcessTotal = 0;
        var assignmentsByModel = new SortedDictionary<string, int>(StringComparer.Ordinal);
        foreach (var stage in Stages)
        {
            // A slot that was launched but never reached a durable ending
            // contributes no census, and the difference between the two counts is
            // what tells a reader the audit's total is short rather than small.
            //
            // Asked of BOTH the committed state and the signed launch ledger. The
            // supervisor creates the process before it returns, and the 'running'
            // rank is committed on the line after, so a coordinator killed in that
            // instant leaves a child that really started and a state that never
            // recorded it. Reading only the state there would publish a spend of
            // zero for a reviewer that may have started every model its plan
            // allowed; the ledger commits its intent one step EARLIER than the
            // process exists, which is exactly the witness that window needs.
            if (_state.EvidenceFor(stage.Running) is not null || LedgerSawLaunch(stage.RunStep))
            {
                launchedSlots++;
            }
            var terminal = _state.EvidenceAtRank(PreparationStateNames.RankOf(stage.TerminalVerified));
            if (terminal is null)
            {
                continue;
            }
            supervisedCount++;
            var slotStarts = terminal.Get("realModelStartCount");
            if (slotStarts is null)
            {
                // Every terminal this build commits carries a census. One that does
                // not is evidence written by an older build, and an audit that
                // treated its silence as a zero would publish a spend of nothing
                // for a run that may have started forty models.
                censusComplete = false;
            }
            else
            {
                realStartTotal += (int)(terminal.GetInteger("realModelStartCount") ?? 0);
                realStartGeneralist += (int)(terminal.GetInteger("realModelStartsGeneralist") ?? 0);
                realStartSpecialist += (int)(terminal.GetInteger("realModelStartsSpecialist") ?? 0);
                realStartVerifier += (int)(terminal.GetInteger("realModelStartsVerifier") ?? 0);
                if (terminal.GetFlag("realModelStartCensusComplete") != true)
                {
                    censusComplete = false;
                }
                // A run interrupted mid-attempt may have started models whose
                // records it never wrote, and the reviewed side has already
                // computed how many against that run's own sealed plan. Carried
                // as an explicit allowance so a ceiling is checked against an
                // upper bound rather than against a floor. An audit whose slot
                // does not state it cannot be spent.
                var slotAllowance = terminal.GetInteger("realModelStartUnmeasuredAllowance");
                if (slotAllowance is null)
                {
                    censusComplete = false;
                }
                else
                {
                    unmeasuredAllowance += (int)slotAllowance;
                }
            }
            // The assignment census, summed in its own unit. A slot whose terminal
            // does not carry one was written by an older build, and an audit that
            // read that silence as zero would publish a verifier spend of nothing
            // for a run that stood on forty assignments - which is precisely the
            // under-count this replaced.
            var slotAssignments = terminal.GetInteger("realVerifierAssignmentCount");
            if (slotAssignments is null)
            {
                assignmentCensusComplete = false;
            }
            else
            {
                assignmentTotal += (int)slotAssignments;
                verifierProcessTotal += (int)(terminal.GetInteger("verifierProcessStartCount") ?? 0);
                if (terminal.GetFlag("realVerifierAssignmentCensusComplete") != true)
                {
                    assignmentCensusComplete = false;
                }
                var slotAssignmentAllowance = terminal.GetInteger("realVerifierAssignmentUnmeasuredAllowance");
                if (slotAssignmentAllowance is null)
                {
                    assignmentCensusComplete = false;
                }
                else
                {
                    assignmentAllowance += (int)slotAssignmentAllowance;
                }
                if (terminal.Get("realVerifierAssignmentsByModel") is ListNode slotByModel)
                {
                    foreach (var item in slotByModel.Items)
                    {
                        if (item is not MapNode row)
                        {
                            continue;
                        }
                        var model = row.GetText("verifierModel");
                        var count = row.GetInteger("assignmentCount");
                        if (model is not { Length: > 0 } || count is null)
                        {
                            assignmentCensusComplete = false;
                            continue;
                        }
                        assignmentsByModel[model] = assignmentsByModel.TryGetValue(model, out var running)
                            ? running + (int)count
                            : (int)count;
                    }
                }
                else
                {
                    assignmentCensusComplete = false;
                }
            }
            // Every one of these is a passthrough of what the reviewed verifier
            // read out of the owner's immutable artifact. This coordinator adds
            // no interpretation, and the audit must not read as though it had.
            slotRecords.Add(new MapNode()
                .Set("slotOrdinal", stage.Ordinal)
                .Set("slotName", terminal.Get("slotName") ?? Node.Null())
                .Set("slotSetId", terminal.Get("setId") ?? Node.Null())
                .Set("slotPlanDigest", terminal.Get("planDigest") ?? Node.Null())
                .Set("slotTerminalStatus", terminal.Get("terminalStatus") ?? Node.Null())
                .Set("slotTerminalExitCode", terminal.Get("terminalExitCode") ?? Node.Null())
                .Set("slotTerminalTimedOut", terminal.Get("terminalTimedOut") ?? Node.Null())
                .Set("slotTerminalSha256", terminal.Get("terminalSha256") ?? Node.Null())
                .Set("slotAttemptCount", terminal.Get("slotAttemptCount") ?? Node.Null())
                .Set("slotAttemptRecordCount", terminal.Get("slotAttemptRecordCount") ?? Node.Null())
                .Set("slotRealModelStartCount", terminal.Get("realModelStartCount") ?? Node.Null())
                .Set("slotRealModelStartsGeneralist", terminal.Get("realModelStartsGeneralist") ?? Node.Null())
                .Set("slotRealModelStartsSpecialist", terminal.Get("realModelStartsSpecialist") ?? Node.Null())
                .Set("slotRealModelStartsVerifier", terminal.Get("realModelStartsVerifier") ?? Node.Null())
                .Set("slotRealModelStartCensusComplete", terminal.Get("realModelStartCensusComplete") ?? Node.Null())
                .Set("slotRealModelStartCensusExact", terminal.Get("realModelStartCensusExact") ?? Node.Null())
                .Set("slotRealVerifierAssignmentCount", terminal.Get("realVerifierAssignmentCount") ?? Node.Null())
                .Set("slotRealVerifierAssignmentsByModel", terminal.Get("realVerifierAssignmentsByModel") ?? Node.Null())
                .Set("slotRealVerifierAssignmentCensusComplete", terminal.Get("realVerifierAssignmentCensusComplete") ?? Node.Null())
                .Set("slotRealVerifierAssignmentUnmeasuredAllowance", terminal.Get("realVerifierAssignmentUnmeasuredAllowance") ?? Node.Null())
                .Set("slotVerifierProcessStartCount", terminal.Get("verifierProcessStartCount") ?? Node.Null())
                .Set("slotSupervision", _state.EvidenceFor(stage.TerminalObserved)?.Get("supervision") ?? Node.Null()));
        }
        if (launchedSlots > supervisedCount)
        {
            censusComplete = false;
            assignmentCensusComplete = false;
        }
        // THE figure a cohort budget is spent in: real model subprocess starts,
        // every role, every attempt, summed from the per-slot censuses this run
        // committed. It is deliberately not derivable from any count of cycles,
        // slots or reviewer processes - that derivation is the defect this
        // replaced, and a two-slot run that starts four models must publish four.
        audit.Set("realModelStartsObserved", supervisedCount > 0);
        audit.Set("realModelStartCount", realStartTotal);
        audit.Set("realModelStartsGeneralist", realStartGeneralist);
        audit.Set("realModelStartsSpecialist", realStartSpecialist);
        audit.Set("realModelStartsVerifier", realStartVerifier);
        audit.Set("realModelStartCensusComplete", censusComplete);
        audit.Set("realModelStartUnmeasuredAllowance", unmeasuredAllowance);
        audit.Set("realModelStartLaunchedSlotCount", launchedSlots);
        // THE figure a cohort's VERIFIER ceiling is spent in, and a different unit
        // from the one above: one assignment is one candidate paired with one
        // required reciprocal model, counted from the sealed per-slot preview
        // manifests. It is deliberately not derivable from any count of terminal
        // states - that derivation is the defect this replaced, and a run that
        // stood on forty assignments must publish forty rather than four.
        audit.Set("realVerifierAssignmentsObserved", supervisedCount > 0);
        audit.Set("realVerifierAssignmentCount", assignmentTotal);
        var assignmentBreakdown = new ListNode();
        foreach (var pair in assignmentsByModel)
        {
            assignmentBreakdown.Add(new MapNode().Set("verifierModel", pair.Key).Set("assignmentCount", pair.Value));
        }
        audit.Set("realVerifierAssignmentsByModel", assignmentBreakdown);
        audit.Set("realVerifierAssignmentCensusComplete", assignmentCensusComplete);
        audit.Set("realVerifierAssignmentUnmeasuredAllowance", assignmentAllowance);
        // Grouped launches. A cluster of candidates can be verified by one
        // subprocess, so this is always a diagnostic and never a budget unit: a
        // ceiling checked against it would shrink every time grouping worked.
        audit.Set("verifierProcessStartCount", verifierProcessTotal);
        audit.Set("declaredSlotCount", CoordinatorRequest.DeclaredSlotCount);
        audit.Set("supervisedSlotCount", supervisedCount);
        audit.Set("slots", slotRecords);
        // The reconciliation reports status, digests and an opaque census, and
        // nothing else. The counters are copied across by position with their
        // names attached; no line in this program compares one of those names to
        // anything, so no reading of the comparison can leak into the audit as a
        // judgement dressed up as a field.
        var reconciled = _state.EvidenceFor(PreparationState.ReconciliationVerified);
        audit.Set("reconciliationPerformed", reconciled is not null);
        if (reconciled is not null)
        {
            audit
                .Set("reconciliationStatus", reconciled.Get("reconciliationStatus") ?? Node.Null())
                .Set("reconciliationSha256", reconciled.Get("reconciliationSha256") ?? Node.Null())
                .Set("reconciliationReportSha256", reconciled.Get("reportSha256") ?? Node.Null())
                .Set("reconciliationArtifactSha256", reconciled.Get("artifactSha256") ?? Node.Null())
                .Set("reconciliationSummarySha256", reconciled.Get("summarySha256") ?? Node.Null())
                .Set("reconciliationRunCount", reconciled.Get("runCount") ?? Node.Null())
                .Set("reconciliationPromotable", reconciled.Get("promotable") ?? Node.Null())
                .Set("reconciliationCounts", reconciled.Get("counts") ?? Node.Null());
        }
        // Named for a reader who wants the one-line answer to "did this write
        // anything anywhere". It is read out of the committed delivery record
        // rather than restated as a constant, so the claim is measured on the
        // runs that evaluated a decision - and the transition that committed it
        // refuses any non-zero count, so there is no reachable record this could
        // read a write out of. A run that never reached a delivery says so with
        // the same two fields, because "no delivery happened" and "a delivery
        // happened and wrote nothing" are both answers to the question and
        // neither is a write.
        var delivered = _state.EvidenceFor(PreparationState.DeliveryTerminalVerified);
        audit.Set("deliveryPerformed", delivered is not null);
        // The reviewed plan's own word for the posture, unchanged from the slice
        // that could not deliver at all, because the posture has not changed.
        audit.Set("deliveryMode", "previewOnly");
        audit.Set("deliveryAuthorizationKind", delivered?.Get("authorizationKind") ?? Node.Text(DeliveryAuthorization.PreviewOnlyKind));
        audit.Set("providerWriteCount", delivered?.Get("providerWriteCount") ?? Node.Number(0));
        audit.Set("writeToolInvocations", delivered?.Get("writeToolInvocations") ?? Node.Number(0));
        if (delivered is not null)
        {
            // Status, digests and an opaque census, on exactly the terms the
            // reconciliation gets: the names are labels for a human reading the
            // audit, and no line in this program compares one of them to
            // anything.
            audit
                .Set("deliveryStatus", delivered.Get("deliveryStatus") ?? Node.Null())
                .Set("deliveryDecisionSha256", delivered.Get("decisionSha256") ?? Node.Null())
                .Set("deliverySummarySha256", delivered.Get("summarySha256") ?? Node.Null())
                .Set("deliveryReconciliationSha256", delivered.Get("reconciliationSha256") ?? Node.Null())
                .Set("deliveryRunCount", delivered.Get("runCount") ?? Node.Null())
                .Set("deliveryPromotable", delivered.Get("promotable") ?? Node.Null())
                .Set("deliveryCommentsEnabled", delivered.Get("commentsEnabled") ?? Node.Null())
                .Set("deliveryVotesEnabled", delivered.Get("votesEnabled") ?? Node.Null())
                .Set("deliveryGatesEnabled", delivered.Get("gatesEnabled") ?? Node.Null())
                .Set("deliveryCounts", delivered.Get("counts") ?? Node.Null());
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
        // Why this run is at rest, and what the record it reports on digests to.
        // Together they are what lets a reader tell an audit that describes a
        // finished run from one that describes a run that stopped in the middle,
        // and tell an audit that matches the state beside it from one left over
        // from an earlier walk.
        audit.Set("terminalReason", terminalReason);
        audit.Set("terminalDetail", terminalDetail);
        // Whether this audit describes a run that is at rest, stated as a flag
        // rather than left to be inferred from the reason word.
        //
        // The audit is rewritten after every commit, so at any instant the copy
        // on disk describes the run as it then stood. A coordinator killed
        // outright - a hard kill, a lost machine - never writes the final one,
        // and the copy left behind is whichever mid-walk audit was written last.
        // Read as an ending, that copy would report the spend of a run that had
        // only reached its own middle, and a cohort would charge it and launch
        // the next entry. It cannot be told apart by counters: the honest ones
        // for the point it was written at are the same zeros a preparation that
        // really refused before launching anything publishes. This flag is the
        // difference, and a reader that requires it true is refusing exactly the
        // audit nobody finished.
        audit.Set(
            "preparationEnded",
            !string.Equals(terminalReason, AuditReasonRunning, StringComparison.Ordinal)
            && !string.Equals(terminalReason, AuditReasonTransitionCommitted, StringComparison.Ordinal));
        audit.Set("stateSha256", File.Exists(_request.StatePath) ? CanonicalJson.Sha256HexOfFile(_request.StatePath) : "none");
        // The launch census comes from the intent ledger rather than from a
        // counter in this process, for the reason the child-result census does:
        // an in-memory count cannot see a launch an earlier process made.
        audit.Set("launchIntents", _ledger.DescribeCensus());
        audit.Set("auditSha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(audit)));
        // Signed with the same key the state record is signed with, so an audit
        // that was edited after the fact cannot pass as one this coordinator
        // wrote. The self-hash above catches a careless edit; only the signature
        // catches a careful one, because a careful editor recomputes the hash.
        audit.Set("signature", CanonicalJson.HmacHex(_stateKey, CanonicalJson.Canonical(audit)));
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

/// <summary>
/// One declared slot's position in the walk: which states it commits, and which
/// child steps carry its work.
/// </summary>
/// <remarks>
/// Every slot-shaped method takes one of these rather than reading a slot name
/// out of a field, so there is no code path that supervises "the slot" and could
/// be pointed at the wrong one. The step names differ per slot too, which is what
/// gives each slot its own exchange files, its own nonces and its own adoption
/// scope: a result published for slot1 can never be adopted as slot2's answer.
/// </remarks>
internal sealed record SlotStage(
    int Ordinal,
    string Name,
    PreparationState Authorized,
    PreparationState Launching,
    PreparationState Running,
    PreparationState TerminalObserved,
    PreparationState TerminalVerified,
    PreparationState TerminalFailed,
    PreparationState TerminalTimedOut,
    string PlanStep,
    string PrelaunchStep,
    string RunStep,
    string VerifyStep);

/// <summary>
/// The reviewed comparison as the coordinator needs to see it: which set, which
/// plan, how many runs, where the output goes, and whether the single
/// authorization has been spent.
/// </summary>
/// <remarks>
/// Nothing in it describes a finding, a candidate or a verdict, because nothing
/// this coordinator does with a reconciliation requires knowing what one said.
/// </remarks>
internal sealed record ReconciliationPlan(
    string SetId,
    string PlanDigest,
    int RequiredRunCount,
    int ArtifactCount,
    string OutputDirectory,
    bool AttemptExists,
    string Head,
    SlotDeadlines Deadlines,
    string ChildResultSha256);

/// <summary>
/// What a step reports about what it could write. Every field is a claim that
/// something is off.
/// </summary>
/// <remarks>
/// Deliberately a separate type from the plan it arrives with, because it is
/// read from three different steps - the authorization's plan, the prelaunch
/// probe and the verified decision - and all three are refused by one method
/// over one shape. A capability that only some of those checked would be a
/// capability that a resumed or re-entered run could carry past the one place
/// that looked.
/// </remarks>
internal sealed record DeliveryCapability(
    string AuthorizationKind,
    bool CommentsEnabled,
    bool VotesEnabled,
    bool GatesEnabled,
    bool Promotable)
{
    internal static DeliveryCapability Read(JsonElement result, string label, string promotableField = "promotable") => new(
        StrictJson.RequireString(result, "authorizationKind", label),
        StrictJson.RequireBool(result, "commentsEnabled", label),
        StrictJson.RequireBool(result, "votesEnabled", label),
        StrictJson.RequireBool(result, "gatesEnabled", label),
        StrictJson.RequireBool(result, promotableField, label));

    internal MapNode Describe() => new MapNode()
        .Set("authorizationKind", AuthorizationKind)
        .Set("commentsEnabled", CommentsEnabled)
        .Set("votesEnabled", VotesEnabled)
        .Set("gatesEnabled", GatesEnabled)
        .Set("promotable", Promotable);
}

/// <summary>
/// The reviewed delivery evaluation as the coordinator needs to see it: which
/// set, which plan, which comparison it closes over, which config and policy it
/// would run under, what it may write, and whether its single authorization has
/// been spent.
/// </summary>
/// <remarks>
/// Nothing in it describes a finding, a candidate, a severity or a verdict. The
/// only thing it says about the decision itself is what the decision is not
/// allowed to be.
/// </remarks>
internal sealed record DeliveryPlan(
    string SetId,
    string PlanDigest,
    int RequiredRunCount,
    string OutputDirectory,
    bool AttemptExists,
    string Head,
    string ReconciliationSha256,
    string ReconciliationArtifactPath,
    string ReconciliationArtifactSha256,
    string ConfigSha256,
    string PolicySha256,
    DeliveryCapability Capability,
    SlotDeadlines Deadlines,
    string ChildResultSha256);
