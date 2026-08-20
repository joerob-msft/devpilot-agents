using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>The transitions this coordinator owns, in the only order they may occur.</summary>
/// <remarks>
/// Three slices live here. The first prepares a run set and stops at
/// <see cref="RunSetReady"/>. The second supervises the first slot from there.
/// The third supervises the second slot, and only then closes the set with a
/// reconciliation.
///
/// No model, no candidate, no severity, no verdict and no delivery appears in
/// this enumeration. What cannot be named here cannot be reached by mistake, and
/// the absence of a delivery state is the structural reason this coordinator
/// cannot write anywhere: there is no transition under which it would.
///
/// Two ranks hold three members rather than one. A supervised run ends verified,
/// failed or timed out, and those are three different durable facts about the
/// same transition - not three points on a line. They are therefore siblings at
/// one rank, and the machine walks ranks rather than enum values; see
/// <see cref="PreparationStateNames.RankOf"/>. The reconciliation has no such
/// fan-out: it either produced the reviewed comparison's own artifacts or it
/// did not, and not producing them is an exception rather than a durable
/// ending, because there is no second reading of a comparison for this
/// coordinator to record. It is one-shot all the same, which is why it has a
/// running rank: a resumed run adopts the comparison it already started rather
/// than discovering a spent authorization it cannot explain.
/// </remarks>
internal enum PreparationState
{
    Start = 0,
    RequestValidated = 1,
    CorpusStaging = 2,
    CorpusPublished = 3,
    CorpusValidated = 4,
    RecipePlanned = 5,
    SnapshotValidateOnly = 6,
    SnapshotSealed = 7,
    SnapshotVerified = 8,
    RunSetDeclared = 9,
    RunSetVerified = 10,
    RunSetReady = 11,
    Slot1Authorized = 12,
    Slot1Launching = 13,
    Slot1Running = 14,
    Slot1TerminalObserved = 15,
    Slot1TerminalVerified = 16,
    Slot1TerminalFailed = 17,
    Slot1TerminalTimedOut = 18,
    Slot2Authorized = 19,
    Slot2Launching = 20,
    Slot2Running = 21,
    Slot2TerminalObserved = 22,
    Slot2TerminalVerified = 23,
    Slot2TerminalFailed = 24,
    Slot2TerminalTimedOut = 25,
    ReconciliationAuthorized = 26,
    ReconciliationLaunching = 27,
    ReconciliationRunning = 28,
    ReconciliationTerminalObserved = 29,
    ReconciliationVerified = 30
}

internal static class PreparationStateNames
{
    /// <summary>The rank the first slot's three terminal outcomes share.</summary>
    internal const int Slot1TerminalRank = 16;

    /// <summary>The rank the second slot's three terminal outcomes share.</summary>
    internal const int Slot2TerminalRank = 21;

    /// <summary>The last rank there is, and the only ending the whole set has.</summary>
    internal const int ReconciliationRank = 26;

    /// <summary>The last rank the preparation slice reaches on its own.</summary>
    internal const int PreparationRank = 11;

    private static readonly (PreparationState State, string Name, int Rank)[] Pairs =
    [
        (PreparationState.Start, "start", 0),
        (PreparationState.RequestValidated, "requestValidated", 1),
        // Building the corpus comes before validating it, because a corpus that
        // does not exist yet cannot be validated and a corpus that has been
        // published must not be rebuilt. Two ranks rather than one: what is on
        // disk after a kill differs completely either side of the publish, and a
        // single rank could not say which side a resumed run is on.
        (PreparationState.CorpusStaging, "corpusStaging", 2),
        (PreparationState.CorpusPublished, "corpusPublished", 3),
        (PreparationState.CorpusValidated, "corpusValidated", 4),
        (PreparationState.RecipePlanned, "recipePlanned", 5),
        (PreparationState.SnapshotValidateOnly, "snapshotValidateOnly", 6),
        (PreparationState.SnapshotSealed, "snapshotSealed", 7),
        (PreparationState.SnapshotVerified, "snapshotVerified", 8),
        (PreparationState.RunSetDeclared, "runSetDeclared", 9),
        (PreparationState.RunSetVerified, "runSetVerified", 10),
        (PreparationState.RunSetReady, "runSetReady", PreparationRank),
        (PreparationState.Slot1Authorized, "slot1Authorized", 12),
        (PreparationState.Slot1Launching, "slot1Launching", 13),
        (PreparationState.Slot1Running, "slot1Running", 14),
        (PreparationState.Slot1TerminalObserved, "slot1TerminalObserved", 15),
        (PreparationState.Slot1TerminalVerified, "slot1TerminalVerified", Slot1TerminalRank),
        (PreparationState.Slot1TerminalFailed, "slot1TerminalFailed", Slot1TerminalRank),
        (PreparationState.Slot1TerminalTimedOut, "slot1TerminalTimedOut", Slot1TerminalRank),
        (PreparationState.Slot2Authorized, "slot2Authorized", 17),
        (PreparationState.Slot2Launching, "slot2Launching", 18),
        (PreparationState.Slot2Running, "slot2Running", 19),
        (PreparationState.Slot2TerminalObserved, "slot2TerminalObserved", 20),
        (PreparationState.Slot2TerminalVerified, "slot2TerminalVerified", Slot2TerminalRank),
        (PreparationState.Slot2TerminalFailed, "slot2TerminalFailed", Slot2TerminalRank),
        (PreparationState.Slot2TerminalTimedOut, "slot2TerminalTimedOut", Slot2TerminalRank),
        (PreparationState.ReconciliationAuthorized, "reconciliationAuthorized", 22),
        (PreparationState.ReconciliationLaunching, "reconciliationLaunching", 23),
        // A running rank for the same reason each slot has one: the comparison is
        // a child process, and a coordinator killed while it runs must be able to
        // name what it left behind instead of finding a spent attempt record it
        // can never account for.
        (PreparationState.ReconciliationRunning, "reconciliationRunning", 24),
        (PreparationState.ReconciliationTerminalObserved, "reconciliationTerminalObserved", 25),
        (PreparationState.ReconciliationVerified, "reconciliationVerified", ReconciliationRank)
    ];

    /// <summary>The ranks at which a supervised run records one of three endings.</summary>
    internal static IReadOnlyList<int> SlotTerminalRanks { get; } = [Slot1TerminalRank, Slot2TerminalRank];

    internal static string ToName(PreparationState state) =>
        Pairs.First(pair => pair.State == state).Name;

    internal static int RankOf(PreparationState state) =>
        Pairs.First(pair => pair.State == state).Rank;

    /// <summary>True when a state is one of the ways a supervised slot ends.</summary>
    internal static bool IsTerminalOutcome(PreparationState state) =>
        SlotTerminalRanks.Contains(RankOf(state));

    /// <summary>
    /// True when a supervised slot ended in a way that stops the set. The words
    /// belong to the terminal artifact, not to this method: all it does is
    /// recognise which of the three durable endings was recorded.
    /// </summary>
    internal static bool IsUnsuccessfulTerminal(PreparationState state) =>
        state is PreparationState.Slot1TerminalFailed
            or PreparationState.Slot1TerminalTimedOut
            or PreparationState.Slot2TerminalFailed
            or PreparationState.Slot2TerminalTimedOut;

    internal static PreparationState Parse(string name)
    {
        foreach (var pair in Pairs)
        {
            if (string.Equals(pair.Name, name, StringComparison.Ordinal))
            {
                return pair.State;
            }
        }
        throw new ContractException($"'{name}' is not a state this coordinator knows.");
    }

    /// <summary>
    /// The ranks the machine walks, in order. Rank is what advances; which of the
    /// three terminal states a terminal rank commits is decided by observed
    /// evidence, not by position in a list.
    /// </summary>
    internal static IReadOnlyList<int> Ranks =>
        Enumerable.Range(1, ReconciliationRank).ToList();

    /// <summary>
    /// The single state at a rank. Refused for the two terminal ranks on purpose:
    /// no caller may pick one of three outcomes by position, because the outcome
    /// is something the supervised run reports rather than something the walk
    /// knows.
    /// </summary>
    internal static PreparationState StateAtRank(int rank)
    {
        if (SlotTerminalRanks.Contains(rank))
        {
            throw new ContractException("A supervised slot's terminal rank holds three outcomes; which one is committed is decided by the evidence, not by rank.");
        }
        foreach (var pair in Pairs)
        {
            if (pair.Rank == rank)
            {
                return pair.State;
            }
        }
        throw new ContractException($"Rank {rank.ToString(CultureInfo.InvariantCulture)} is not a transition this coordinator performs.");
    }

    /// <summary>True when a state belongs to a supervised slot or to the reconciliation.</summary>
    internal static bool IsSlotState(PreparationState state) => RankOf(state) > PreparationRank;
}

internal sealed record TransitionRecord(
    int Sequence,
    PreparationState State,
    string AtUtc,
    string EvidenceSha256,
    string Detail,
    MapNode Evidence);

/// <summary>
/// The durable record of how far this run got.
/// </summary>
/// <remarks>
/// Three properties carry the restart guarantee. The sequence is monotonic, so a
/// state file that went backwards is a refusal rather than a rewind. The record
/// is signed, so a truncated or edited file is refused rather than believed. And
/// the whole file is replaced atomically through a sibling temporary, so a
/// coordinator killed mid-write leaves either the old record or the new one and
/// never half of either.
///
/// The signature is not an adversary defence and is not claimed as one: the key
/// sits beside the state under the same ownership, so anything that can edit the
/// record can re-sign it. What it does catch is the fault this slice actually
/// meets - a partially written, truncated, or hand-edited record being resumed
/// from as though it were evidence.
/// </remarks>
internal sealed class CoordinatorState
{
    internal const string ContractVersionValue = "devpilot.shadow-run-coordinator.state.v1";
    internal const string KindValue = "shadow-run-coordinator-state";

    private readonly List<TransitionRecord> _transitions = [];
    private readonly List<MapNode> _artifacts = [];

    private CoordinatorState(string correlationId, string requestSha256, string subjectSha256)
    {
        CorrelationId = correlationId;
        RequestSha256 = requestSha256;
        SubjectSha256 = subjectSha256;
    }

    internal string CorrelationId { get; }

    internal string RequestSha256 { get; }

    internal string SubjectSha256 { get; }

    internal int Sequence { get; private set; }

    internal PreparationState State { get; private set; } = PreparationState.Start;

    internal IReadOnlyList<TransitionRecord> Transitions => _transitions;

    internal int ArtifactCount => _artifacts.Count;

    internal static CoordinatorState Fresh(CoordinatorRequest request) =>
        new(request.CorrelationId, request.RequestSha256, SubjectDigest(request));

    internal static string SubjectDigest(CoordinatorRequest request) =>
        CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(request.DescribeSubject()));

    /// <summary>
    /// Loads an existing record, or returns a fresh one when there is nothing to
    /// resume. A record that exists but does not belong to this request is a
    /// refusal, never a fresh start: silently starting over would relaunch
    /// children whose evidence is already on disk.
    /// </summary>
    /// <param name="keyPreexisted">
    /// Whether the signing key was already on disk when this process started. The
    /// key is written with the first record and only then, so a key WITHOUT a
    /// record means a record that existed has since been removed. Treating that as
    /// a fresh start is what would make the signed record merely decorative: the
    /// run would mint transitions, clear and republish stage artifacts, and only
    /// later notice a standing snapshot. The refusal happens here, before anything
    /// is mutated.
    /// </param>
    internal static CoordinatorState LoadOrFresh(CoordinatorRequest request, byte[] key, bool keyPreexisted)
    {
        if (!File.Exists(request.StatePath))
        {
            // The key is a strong signal, not a sufficient one. A crash between
            // writing the key and writing the record it signs leaves the same
            // shape as a destroyed record, and refusing on that alone would make
            // a first attempt that died before it committed anything - a failed
            // validation, an interrupted start - permanently unrecoverable, which
            // is the very failure class the rest of this machine exists to avoid.
            // What actually distinguishes the two is whether the root holds WORK.
            if (keyPreexisted && DescribeStandingWork(request) is { } work)
            {
                throw new ContractException(
                    $"The output root '{request.OutputRoot}' carries a coordinator signing key and {work}, but no state record at '{request.StatePath}'. " +
                    "The record this run would have resumed from has been removed, so its side effects cannot be accounted for. " +
                    "This root is not resumable and is not started over; use a fresh output root.");
            }
            return Fresh(request);
        }

        const string label = "shadow run coordinator state";
        var root = StrictJson.ReadObjectFile(request.StatePath, label);
        StrictJson.RequireNoUnknownFields(
            root,
            label,
            "contractVersion",
            "kind",
            "correlationId",
            "requestSha256",
            "subjectSha256",
            "sequence",
            "state",
            "transitions",
            "artifacts",
            "signature");

        StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, label);
        StrictJson.RequireLiteral(root, "kind", KindValue, label);

        var signature = StrictJson.RequireObject(root, "signature", label);
        StrictJson.RequireNoUnknownFields(signature, label + " signature", "algorithm", "value");
        StrictJson.RequireLiteral(signature, "algorithm", "HMACSHA256", label + " signature");
        var recordedSignature = StrictJson.RequireHex(signature, "value", label + " signature", 64);

        var correlationId = StrictJson.RequireString(root, "correlationId", label);
        var requestSha256 = StrictJson.RequireHex(root, "requestSha256", label, 64);
        var subjectSha256 = StrictJson.RequireHex(root, "subjectSha256", label, 64);
        var sequence = StrictJson.RequireInt(root, "sequence", label, 0, int.MaxValue);
        var stateName = StrictJson.RequireString(root, "state", label);
        var artifacts = StrictJson.RequireArray(root, "artifacts", label);
        var transitions = StrictJson.RequireArray(root, "transitions", label);

        var state = new CoordinatorState(correlationId, requestSha256, subjectSha256)
        {
            Sequence = sequence,
            State = PreparationStateNames.Parse(stateName)
        };

        var previousSequence = 0;
        foreach (var entry in transitions)
        {
            if (entry.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {label} transitions hold a {StrictJson.Describe(entry.ValueKind)}, not an object.");
            }
            StrictJson.RequireNoUnknownFields(entry, label + " transition", "sequence", "state", "atUtc", "evidenceSha256", "detail", "evidence");
            var entrySequence = StrictJson.RequireInt(entry, "sequence", label + " transition", 1, int.MaxValue);
            if (entrySequence <= previousSequence)
            {
                throw new ContractException($"The {label} transition sequence went from {previousSequence.ToString(CultureInfo.InvariantCulture)} to {entrySequence.ToString(CultureInfo.InvariantCulture)}; a durable sequence only ever increases.");
            }
            previousSequence = entrySequence;
            var evidence = (MapNode)Node.FromJson(
                StrictJson.RequireObject(entry, "evidence", label + " transition"),
                label + " transition evidence");
            var evidenceSha256 = StrictJson.RequireHex(entry, "evidenceSha256", label + " transition", 64);
            // The digest is re-derived from the restored evidence rather than
            // trusted. The signature already covers both, so a mismatch means the
            // two were never consistent - which would let a resumed run publish an
            // audit that disagrees with the digest it claims.
            var recomputed = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(evidence));
            if (!string.Equals(recomputed, evidenceSha256, StringComparison.Ordinal))
            {
                throw new ContractException($"The {label} transition at sequence {entrySequence.ToString(CultureInfo.InvariantCulture)} records evidence digesting to {recomputed} and claims {evidenceSha256}.");
            }
            state._transitions.Add(new TransitionRecord(
                entrySequence,
                PreparationStateNames.Parse(StrictJson.RequireString(entry, "state", label + " transition")),
                StrictJson.RequireString(entry, "atUtc", label + " transition"),
                evidenceSha256,
                StrictJson.RequireString(entry, "detail", label + " transition"),
                evidence));
        }

        foreach (var artifact in artifacts)
        {
            if (artifact.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {label} artifacts hold a {StrictJson.Describe(artifact.ValueKind)}, not an object.");
            }
            state._artifacts.Add(StageArtifactIndex.RereadIndexEntry(artifact));
        }

        if (previousSequence != sequence)
        {
            throw new ContractException($"The {label} says sequence {sequence.ToString(CultureInfo.InvariantCulture)} but its last transition is {previousSequence.ToString(CultureInfo.InvariantCulture)}.");
        }
        if (state._transitions.Count > 0 && state._transitions[^1].State != state.State)
        {
            throw new ContractException($"The {label} says state '{stateName}' but its last transition recorded '{PreparationStateNames.ToName(state._transitions[^1].State)}'.");
        }

        var expected = CanonicalJson.HmacHex(key, CanonicalJson.Canonical(state.Compose(includeSignature: false)));
        if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expected), Convert.FromHexString(recordedSignature)))
        {
            throw new ContractException($"The {label} at '{request.StatePath}' does not match its own signature; it was truncated or edited after it was written.");
        }

        if (!string.Equals(correlationId, request.CorrelationId, StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} belongs to correlation '{correlationId}', and this request carries '{request.CorrelationId}'.");
        }
        if (!string.Equals(requestSha256, request.RequestSha256, StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} was written for a different request; resuming under changed inputs is refused.");
        }
        if (!string.Equals(subjectSha256, SubjectDigest(request), StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} was written for a different subject; resuming onto another pull request or iteration is refused.");
        }
        return state;
    }

    internal void RecordArtifact(MapNode artifact) => _artifacts.Add(artifact);

    /// <summary>The committed evidence digest for a state, or a placeholder when it holds none.</summary>
    internal string EvidenceDigestOf(PreparationState state)
    {
        foreach (var transition in _transitions)
        {
            if (transition.State == state)
            {
                return transition.EvidenceSha256;
            }
        }
        return "none";
    }

    /// <summary>The committed evidence for a state, or null when there is none.</summary>
    internal MapNode? EvidenceFor(PreparationState state)
    {
        foreach (var transition in _transitions)
        {
            if (transition.State == state)
            {
                return transition.Evidence;
            }
        }
        return null;
    }

    /// <summary>
    /// The committed evidence for a rank, whichever state at that rank was
    /// recorded. The terminal rank has three members, so a reader that has to ask
    /// "what did the run end on" cannot name the state it is looking for.
    /// </summary>
    internal MapNode? EvidenceAtRank(int rank)
    {
        foreach (var transition in _transitions)
        {
            if (PreparationStateNames.RankOf(transition.State) == rank)
            {
                return transition.Evidence;
            }
        }
        return null;
    }

    /// <summary>
    /// Commits one transition. The state file on disk is replaced before this
    /// returns, so the caller may be killed immediately afterwards and a resume
    /// will still see the transition as done.
    /// </summary>
    internal void Commit(CoordinatorRequest request, byte[] key, PreparationState next, MapNode evidence, string detail)
    {
        // Rank, not enum value. The three terminal outcomes share a rank because
        // they are three answers to one transition; comparing raw enum values here
        // would make 'failed' look like a step that follows 'verified'.
        if (PreparationStateNames.RankOf(next) != PreparationStateNames.RankOf(State) + 1)
        {
            throw new ContractException($"A transition to '{PreparationStateNames.ToName(next)}' from '{PreparationStateNames.ToName(State)}' skips a state; the machine only moves one step at a time.");
        }
        Sequence++;
        State = next;
        _transitions.Add(new TransitionRecord(
            Sequence,
            next,
            DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture),
            CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(evidence)),
            detail,
            evidence));
        Save(request, key);
    }

    internal void Save(CoordinatorRequest request, byte[] key)
    {
        // The key goes down first, and only ever here. Until a record exists there
        // is nothing for it to sign, and its presence is what later proves a
        // record was removed rather than never written.
        var effective = PersistKey(request, key);
        var unsigned = Compose(includeSignature: false);
        var signature = CanonicalJson.HmacHex(effective, CanonicalJson.Canonical(unsigned));        var signed = Compose(includeSignature: false);
        signed.Set("signature", new MapNode().Set("algorithm", "HMACSHA256").Set("value", signature));
        CanonicalJson.WriteFileAtomic(request.StatePath, CanonicalJson.Readable(signed));
    }

    internal MapNode Compose(bool includeSignature)
    {
        var transitions = new ListNode();
        foreach (var transition in _transitions)
        {
            transitions.Add(new MapNode()
                .Set("sequence", transition.Sequence)
                .Set("state", PreparationStateNames.ToName(transition.State))
                .Set("atUtc", transition.AtUtc)
                .Set("evidenceSha256", transition.EvidenceSha256)
                .Set("detail", transition.Detail)
                .Set("evidence", transition.Evidence));
        }
        var artifacts = new ListNode();
        foreach (var artifact in _artifacts)
        {
            artifacts.Add(artifact);
        }
        var map = new MapNode()
            .Set("contractVersion", ContractVersionValue)
            .Set("kind", KindValue)
            .Set("correlationId", CorrelationId)
            .Set("requestSha256", RequestSha256)
            .Set("subjectSha256", SubjectSha256)
            .Set("sequence", Sequence)
            .Set("state", PreparationStateNames.ToName(State))
            .Set("transitions", transitions)
            .Set("artifacts", artifacts);
        if (includeSignature)
        {
            map.Set("signature", new MapNode().Set("algorithm", "HMACSHA256").Set("value", new string('0', 64)));
        }
        return map;
    }

    /// <summary>
    /// The signing key for this output root, minted once and reused. A run that
    /// finds no key mints one in memory; a resume that finds one uses it, because
    /// a new key would make every existing record unverifiable and turn a restart
    /// into a silent fresh start.
    /// </summary>
    /// <remarks>
    /// A minted key is deliberately NOT written here. The key's presence is the
    /// evidence that a record once existed, so writing it before the record it
    /// signs would make an ordinary first-attempt crash - a failed validation, a
    /// kill before the first commit - indistinguishable from a destroyed record,
    /// and would wedge a root that has published nothing at all. It is persisted
    /// by <see cref="Save"/>, alongside the first record, and only then.
    /// </remarks>
    internal static byte[] LoadOrMintKey(CoordinatorRequest request, out bool preexisted)
    {
        Directory.CreateDirectory(request.CoordinatorRoot);
        if (File.Exists(request.StateKeyPath))
        {
            preexisted = true;
            return ReadKey(request);
        }
        preexisted = false;
        return RandomNumberGenerator.GetBytes(32);
    }

    /// <summary>
    /// The supervised child this output root's signed record says it left running,
    /// or null when the record names none, cannot be verified, or does not exist.
    /// </summary>
    /// <remarks>
    /// Read before the lease is taken, and therefore deliberately read-only: it
    /// mints no key, writes nothing, and answers null for every root that has not
    /// already committed a running child under a key it holds. Its only use is to
    /// tell the one child a resumed run is entitled to adopt from a child that
    /// merely happens to be alive - and because the answer comes from the signed
    /// record, a forged journal cannot manufacture that entitlement.
    ///
    /// The reconciliation is asked about first and the slots in reverse order,
    /// which is simply latest-first: only the most recently committed running
    /// record can name a child that is still alive, and an earlier one names a
    /// process this run has already watched end.
    /// </remarks>
    internal static (int ProcessId, string StartedAtUtc)? TryReadRecordedSlotChild(CoordinatorRequest request)
    {
        if (!File.Exists(request.StateKeyPath) || !File.Exists(request.StatePath))
        {
            return null;
        }
        CoordinatorState state;
        try
        {
            state = LoadOrFresh(request, ReadKey(request), keyPreexisted: true);
        }
        catch (ContractException)
        {
            // An unverifiable record grants no entitlement. The run that follows
            // will refuse on the same record with a message about the record,
            // which is a better refusal than one about a live child.
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        var child = state.EvidenceFor(PreparationState.ReconciliationRunning)?.Get("child") as MapNode
            ?? state.EvidenceFor(PreparationState.Slot2Running)?.Get("child") as MapNode
            ?? state.EvidenceFor(PreparationState.Slot1Running)?.Get("child") as MapNode;
        if (child is null)
        {
            return null;
        }
        var startedAt = child.GetText("childStartedAtUtc");
        if (startedAt is not { Length: > 0 } || child.GetInteger("childProcessId") is not { } processId)
        {
            return null;
        }
        return ((int)processId, startedAt);
    }

    /// <summary>
    /// Writes the minted key if this root has none, and adopts an existing one if
    /// something else won the race. Minting a second key would make every record
    /// written under the first unverifiable.
    /// </summary>
    /// <summary>
    /// Names the first durable side effect this output root holds, or null when it
    /// holds none. Only these say that a preparation got far enough to do
    /// something a later run would have to account for.
    /// </summary>
    private static string? DescribeStandingWork(CoordinatorRequest request)
    {
        if (File.Exists(request.AuditPath))
        {
            return "a published audit";
        }
        // Only when this run was the one authorized to build the corpus. When it
        // was not, the corpus is a caller-supplied input that was there before the
        // run started, and an input is not this root's side effect.
        if (request.CorpusStagingRequested && Directory.Exists(request.CorpusRoot))
        {
            return "a published corpus";
        }
        if (HasAnyFile(request.ExchangeRoot))
        {
            return "child exchange records";
        }
        if (HasAnyFile(request.StageArtifactRoot))
        {
            return "published stage artifacts";
        }
        if (HasAnyFile(request.ReplayRoot))
        {
            return "a sealed replay root";
        }
        if (HasAnyFile(request.QualificationRoot))
        {
            return "a qualification root";
        }
        return null;
    }

    private static bool HasAnyFile(string directory) =>
        Directory.Exists(directory) && Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).Any();

    private static byte[] PersistKey(CoordinatorRequest request, byte[] key)
    {
        if (File.Exists(request.StateKeyPath))
        {
            var standing = ReadKey(request);
            if (!CryptographicOperations.FixedTimeEquals(standing, key))
            {
                throw new ContractException(
                    $"The coordinator signing key at '{request.StateKeyPath}' is not the key this run holds. " +
                    "Another writer minted a key for this output root; the record this run would sign could not be verified against it.");
            }
            return standing;
        }
        try
        {
            using var stream = new FileStream(request.StateKeyPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(key, 0, key.Length);
            stream.Flush(flushToDisk: true);
        }
        catch (IOException) when (File.Exists(request.StateKeyPath))
        {
            throw new ContractException(
                $"Another writer created the coordinator signing key at '{request.StateKeyPath}' while this run was minting one. " +
                "Two coordinators are writing this output root.");
        }
        return key;
    }

    private static byte[] ReadKey(CoordinatorRequest request)
    {
        var existing = File.ReadAllBytes(request.StateKeyPath);
        if (existing.Length != 32)
        {
            throw new ContractException($"The coordinator state key at '{request.StateKeyPath}' is {existing.Length.ToString(CultureInfo.InvariantCulture)} bytes, not 32.");
        }
        return existing;
    }
}
