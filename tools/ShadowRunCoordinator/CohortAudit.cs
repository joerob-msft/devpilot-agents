using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Thrown when a cohort must stop everything, whatever its stop policy says.
/// </summary>
/// <remarks>
/// Reserved for the faults that are not about one entry: a reported write
/// capability, a reported write, an audit this runner cannot read as one of its
/// own. A stop policy decides whether an unsuccessful ENTRY ends the cohort; it
/// has no say over a cohort that has discovered it is not the cohort it was
/// declared to be.
/// </remarks>
internal sealed class CohortBlockedException(string message) : Exception(message)
{
    /// <summary>
    /// The write counters the refused audit published, when the refusal is
    /// itself about them.
    /// </summary>
    /// <remarks>
    /// An observed write is the one reading a cohort must never lose. The entry
    /// that published it is closed without a summary, so without carrying the
    /// counts out with the refusal the closed record would report the zero the
    /// cohort is trying to prove - which is exactly backwards.
    /// </remarks>
    internal int ObservedProviderWriteCount { get; init; }

    internal int ObservedWriteToolInvocationCount { get; init; }
}

/// <summary>
/// One entry's summary, read out of that entry's published audit and carrying
/// nothing a reader could turn back into a review.
/// </summary>
/// <remarks>
/// Every field here is a state word, a digest, an integer or a duration. There is
/// no finding text, no candidate, no severity, no verdict, and no identifying
/// field: the subject appears only as the digest the manifest already publishes,
/// so a reader who does not hold the manifest learns which preparations ran and
/// what they cost, and nothing about what any of them found.
///
/// It is derived rather than accumulated. Everything comes from the per-entry
/// audit on disk, so a cohort killed and resumed eight times publishes exactly
/// the index an uninterrupted one would, and the whole index can be rebuilt from
/// the per-entry artifacts without running anything.
/// </remarks>
internal sealed record CohortEntrySummary
{
    internal required CohortEntry Entry { get; init; }

    internal required CohortEntryRecord Record { get; init; }

    /// <summary>The state the entry's preparation last committed, as its own audit reports it.</summary>
    internal required string PreparationFinalState { get; init; }

    /// <summary>Why that preparation was at rest, in its own closed vocabulary.</summary>
    internal required string PreparationTerminalReason { get; init; }

    internal required string SnapshotEvidenceSha256 { get; init; }

    internal required string RunSetEvidenceSha256 { get; init; }

    internal required string ReconciliationEvidenceSha256 { get; init; }

    internal required string DeliveryEvidenceSha256 { get; init; }

    internal required string ReconciliationSha256 { get; init; }

    internal required string ReconciliationReportSha256 { get; init; }

    internal required string DeliveryDecisionSha256 { get; init; }

    internal required string DeliverySummarySha256 { get; init; }

    internal required string AuditSha256 { get; init; }

    internal required string StateSha256 { get; init; }

    /// <summary>
    /// Real model subprocess starts, every role and every attempt, as the entry's
    /// own audit counted them. THE figure a cohort budget is spent in.
    /// </summary>
    internal required int ModelStartCount { get; init; }

    internal required int ModelStartsGeneralist { get; init; }

    internal required int ModelStartsSpecialist { get; init; }

    internal required int ModelStartsVerifier { get; init; }

    /// <summary>
    /// Real model starts an interrupted entry may have made and could not record,
    /// summed over its slots. Computed on the reviewed side against each run's own
    /// sealed plan, because the size of the gap depends on which phase was
    /// interrupted: an attempt in flight hides one start, while a cross-verifier
    /// phase killed before it seals hides every launch it made. The ceiling is
    /// checked against the measured total plus this.
    /// </summary>
    internal required int ModelStartUnmeasuredAllowance { get; init; }

    /// <summary>
    /// Reviewer PROCESS launches - one attempt record per slot. Diagnostic only:
    /// no budget is checked against it, and the name says which of the two
    /// censuses it is.
    /// </summary>
    internal required int SlotAttemptRecordCount { get; init; }

    internal required int SlotLaunchCount { get; init; }

    internal required int SupervisedSlotCount { get; init; }

    internal required int VerifierAssignmentCount { get; init; }

    internal required int ProviderWriteCount { get; init; }

    internal required int WriteToolInvocationCount { get; init; }

    internal required int WallClockSeconds { get; init; }

    internal MapNode Describe()
    {
        var summary = new MapNode()
            .Set("ordinal", Entry.Ordinal)
            .Set("entryId", Entry.EntryId)
            .Set("subjectSha256", Entry.SubjectSha256)
            .Set("requestSha256", Entry.RequestSha256)
            .Set("ruleBundleSourceKind", Entry.RuleBundleSourceKind)
            .Set("ruleBundleSha256", Entry.RuleBundleSha256)
            .Set("state", Record.State)
            .Set("outcome", Record.Outcome)
            .Set("attempt", Record.Attempt)
            .Set("exitCode", Record.ExitCode)
            .Set("preparationFinalState", PreparationFinalState)
            .Set("preparationTerminalReason", PreparationTerminalReason)
            .Set("snapshotEvidenceSha256", SnapshotEvidenceSha256)
            .Set("runSetEvidenceSha256", RunSetEvidenceSha256)
            .Set("reconciliationEvidenceSha256", ReconciliationEvidenceSha256)
            .Set("deliveryEvidenceSha256", DeliveryEvidenceSha256)
            .Set("reconciliationSha256", ReconciliationSha256)
            .Set("reconciliationReportSha256", ReconciliationReportSha256)
            .Set("deliveryDecisionSha256", DeliveryDecisionSha256)
            .Set("deliverySummarySha256", DeliverySummarySha256)
            .Set("auditSha256", AuditSha256)
            .Set("stateSha256", StateSha256)
            .Set("modelStartCount", ModelStartCount)
            .Set("modelStartsGeneralist", ModelStartsGeneralist)
            .Set("modelStartsSpecialist", ModelStartsSpecialist)
            .Set("modelStartsVerifier", ModelStartsVerifier)
            .Set("modelStartUnmeasuredAllowance", ModelStartUnmeasuredAllowance)
            .Set("slotAttemptRecordCount", SlotAttemptRecordCount)
            .Set("slotLaunchCount", SlotLaunchCount)
            .Set("supervisedSlotCount", SupervisedSlotCount)
            .Set("verifierAssignmentCount", VerifierAssignmentCount)
            .Set("providerWriteCount", ProviderWriteCount)
            .Set("writeToolInvocationCount", WriteToolInvocationCount)
            .Set("wallClockSeconds", WallClockSeconds)
            .Set("deliveryMode", CohortIndex.PreviewOnlyMode);
        summary.Set("summarySha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(summary)));
        return summary;
    }

    /// <summary>The summary of an entry that never ran, which is a shape rather than a set of readings.</summary>
    /// <remarks>
    /// The write counters are the one exception, and they are taken from the
    /// record rather than assumed to be zero. An entry closed because its audit
    /// reported a write is summarized here, and a summary that reported zero for
    /// it would report the opposite of the fact that stopped the cohort.
    /// </remarks>
    internal static CohortEntrySummary NotRun(CohortEntry entry, CohortEntryRecord record) => new()
    {
        Entry = entry,
        Record = record,
        PreparationFinalState = "none",
        PreparationTerminalReason = "none",
        SnapshotEvidenceSha256 = "none",
        RunSetEvidenceSha256 = "none",
        ReconciliationEvidenceSha256 = "none",
        DeliveryEvidenceSha256 = "none",
        ReconciliationSha256 = "none",
        ReconciliationReportSha256 = "none",
        DeliveryDecisionSha256 = "none",
        DeliverySummarySha256 = "none",
        AuditSha256 = "none",
        StateSha256 = "none",
        ModelStartCount = 0,
        ModelStartsGeneralist = 0,
        ModelStartsSpecialist = 0,
        ModelStartsVerifier = 0,
        ModelStartUnmeasuredAllowance = 0,
        SlotAttemptRecordCount = 0,
        SlotLaunchCount = 0,
        SupervisedSlotCount = 0,
        VerifierAssignmentCount = 0,
        ProviderWriteCount = record.ProviderWriteCount,
        WriteToolInvocationCount = record.WriteToolInvocationCount,
        WallClockSeconds = record.ElapsedSeconds
    };
}

/// <summary>
/// Reads one entry's published audit and turns it into the opaque summary a
/// cohort is allowed to carry.
/// </summary>
/// <remarks>
/// Nothing here interprets. Digests are copied across by name, counters are
/// copied across as integers, and the two words that appear - the preparation's
/// final state and its terminal reason - are the audit's own closed vocabularies,
/// which this file compares to nothing. The only arithmetic performed is
/// addition, over counters the audit already published.
/// </remarks>
internal static class CohortSummaryReader
{
    private const string AuditContractVersion = "devpilot.shadow-run-coordinator.audit.v2";
    private const string AuditKind = "shadow-run-coordinator-audit";

    /// <summary>The audit an entry's output root publishes.</summary>
    internal static string AuditPathFor(CohortEntry entry) =>
        Path.Combine(entry.OutputRoot, "coordinator", "audit.json");

    /// <summary>The key the entry's own preparation signed its record and its audit with.</summary>
    internal static string StateKeyPathFor(CohortEntry entry) =>
        Path.Combine(entry.OutputRoot, "coordinator", "state.key");

    /// <summary>
    /// The states at which a reviewed verifier read something on this
    /// preparation's behalf.
    /// </summary>
    /// <remarks>
    /// A structural list, not a policy. Each of these transitions is committed
    /// only after the reviewed side has read an immutable artifact and reported
    /// on it, so counting the committed ones counts the verifier assignments the
    /// preparation actually stood on. No line here reads what any of them
    /// reported.
    /// </remarks>
    private static readonly string[] VerifierBackedStates =
    [
        "slot1TerminalVerified",
        "slot1TerminalFailed",
        "slot1TerminalTimedOut",
        "slot2TerminalVerified",
        "slot2TerminalFailed",
        "slot2TerminalTimedOut",
        "reconciliationVerified",
        "deliveryTerminalVerified"
    ];

    internal static CohortEntrySummary Read(CohortEntry entry, CohortEntryRecord record, int wallClockSeconds, string expectedCorrelationId)
    {
        var path = AuditPathFor(entry);
        var label = $"entry '{entry.EntryId}' preparation audit";
        if (!File.Exists(path))
        {
            // Absent is a fact, not a zero. An entry whose preparation refused its
            // own request before it could write anything has no audit, and a
            // summary that reported zeros would be indistinguishable from one that
            // reported a preparation which ran and consumed nothing.
            return CohortEntrySummary.NotRun(entry, record) with { WallClockSeconds = wallClockSeconds };
        }

        JsonElement audit;
        string auditSha256;
        try
        {
            // Read once, then parse and digest the same bytes. Reading the file a
            // second time to hash it would attest to a file this run never obeyed,
            // and the digest the index publishes is the one thing that says which
            // audit was read. The acquisition itself is inside the guard, so a
            // locked or vanished audit is a refusal that blocks the cohort rather
            // than a filesystem fault: the caller above treats a failure to write
            // the index leniently, and an audit that could not be read must never
            // be mistaken for one.
            var bytes = StrictJson.ReadFileBytes(path, label);
            audit = StrictJson.ReadObjectBytes(bytes, path, label);
            auditSha256 = CanonicalJson.Sha256Hex(bytes);
            StrictJson.RequireLiteral(audit, "contractVersion", AuditContractVersion, label);
            StrictJson.RequireLiteral(audit, "kind", AuditKind, label);
            // The one binding that says this audit belongs to the preparation this
            // entry declared, rather than being an audit left standing in that root
            // by something else. The correlation is the request's own, read out of
            // the request the manifest sealed, so an audit adopted from another
            // preparation is refused instead of counted. The digests beside it are
            // what the manifest already pinned, so an audit left over from an
            // earlier request against the same subject - or against the same
            // correlation - is refused too.
            StrictJson.RequireLiteral(audit, "correlationId", expectedCorrelationId, label);
            StrictJson.RequireLiteral(audit, "requestSha256", entry.RequestSha256, label);
            StrictJson.RequireLiteral(audit, "subjectSha256", entry.SubjectSha256, label);
            RequireAuthentic(entry, audit, path, label);
        }
        catch (ContractException error)
        {
            // An unreadable audit is not one entry's problem. The index this
            // cohort publishes claims to be rebuildable from the per-entry
            // artifacts, and an artifact this runner cannot read as one of its own
            // makes that claim false for the whole set.
            throw new CohortBlockedException(
                $"The {label} at '{path}' cannot be read as an audit this build publishes: {error.Message} " +
                "A cohort index is only worth what the artifacts it indexes are worth, so the whole cohort stops here.");
        }

        var transitionDigests = ReadTransitionDigests(audit, label);
        var verifierAssignments = 0;
        foreach (var state in VerifierBackedStates)
        {
            if (transitionDigests.ContainsKey(state))
            {
                verifierAssignments++;
            }
        }

        var providerWrites = RequireWriteCount(audit, "providerWriteCount", label);
        var writeInvocations = RequireWriteCount(audit, "writeToolInvocations", label);
        RequireZeroWrites(entry, providerWrites, writeInvocations);
        RequireNoWriteCapability(entry, audit, label);
        RequireEnded(entry, audit, label);
        var starts = RequireRealModelStarts(entry, audit, label);

        return new CohortEntrySummary
        {
            Entry = entry,
            Record = record,
            PreparationFinalState = ReadText(audit, "finalState"),
            PreparationTerminalReason = ReadText(audit, "terminalReason"),
            SnapshotEvidenceSha256 = DigestOf(transitionDigests, "snapshotVerified"),
            RunSetEvidenceSha256 = DigestOf(transitionDigests, "runSetReady"),
            ReconciliationEvidenceSha256 = DigestOf(transitionDigests, "reconciliationVerified"),
            DeliveryEvidenceSha256 = DigestOf(transitionDigests, "deliveryTerminalVerified"),
            ReconciliationSha256 = ReadText(audit, "reconciliationSha256"),
            ReconciliationReportSha256 = ReadText(audit, "reconciliationReportSha256"),
            DeliveryDecisionSha256 = ReadText(audit, "deliveryDecisionSha256"),
            DeliverySummarySha256 = ReadText(audit, "deliverySummarySha256"),
            AuditSha256 = auditSha256,
            StateSha256 = ReadText(audit, "stateSha256"),
            ModelStartCount = starts.Total,
            ModelStartsGeneralist = starts.Generalist,
            ModelStartsSpecialist = starts.Specialist,
            ModelStartsVerifier = starts.Verifier,
            ModelStartUnmeasuredAllowance = starts.UnmeasuredAllowance,
            SlotAttemptRecordCount = RequireRepresentable(SlotAttemptRecords(audit), "slotAttemptRecordCount", label),
            SlotLaunchCount = RequireRepresentable(ReadCount(audit, "slotLaunchCount"), "slotLaunchCount", label),
            SupervisedSlotCount = RequireRepresentable(ReadCount(audit, "supervisedSlotCount"), "supervisedSlotCount", label),
            VerifierAssignmentCount = verifierAssignments,
            ProviderWriteCount = providerWrites,
            WriteToolInvocationCount = writeInvocations,
            WallClockSeconds = wallClockSeconds
        };
    }

    /// <summary>
    /// Refuses an audit that nobody finished writing.
    /// </summary>
    /// <remarks>
    /// The preparation rewrites its audit after every commit, so the copy on
    /// disk always describes the run as it then stood, and every way out of the
    /// walk - success, refusal, fault, deliberate halt - rewrites it once more
    /// with an ending. A coordinator killed outright writes no ending, and what
    /// is left is a mid-walk audit whose counters are honest for a point the run
    /// had not yet passed. Its spend is not the entry's spend, and its zeros are
    /// indistinguishable from those of a preparation that really refused before
    /// launching anything.
    ///
    /// So this is asked before any counter is read, and it blocks the whole
    /// cohort: an entry whose evidence stops mid-sentence is one whose cost is
    /// unknown, and the next entry must not be launched against it. An audit
    /// that does not carry the flag at all is evidence from a build that could
    /// not answer the question, which is refused on the same terms.
    /// </remarks>
    private static void RequireEnded(CohortEntry entry, JsonElement audit, string label)
    {
        if (!audit.TryGetProperty("preparationEnded", out var ended)
            || ended.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new CohortBlockedException(
                $"The {label} publishes no 'preparationEnded'. This build refuses an audit that cannot say whether the " +
                "preparation it describes had finished, because a mid-walk audit read as an ending reports the spend of a " +
                "run that had not made it yet.");
        }
        if (ended.ValueKind != JsonValueKind.True)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' published an audit describing a preparation that was still running when the audit " +
                "was written, which is what a coordinator killed outright leaves behind. What that entry spent is unknown " +
                "rather than what the audit happens to say, so the cohort stops here instead of launching another entry.");
        }
    }

    /// <summary>
    /// The real model subprocess starts one entry made, read from its own signed
    /// audit and refused rather than guessed.
    /// </summary>
    /// <remarks>
    /// THE number a cohort budget is spent in. It is read, never derived: the
    /// defect this replaced computed it from a census of reviewer processes, so a
    /// two-slot entry that started four models was accounted as three and one
    /// that started forty would still have been accounted as three.
    ///
    /// Four refusals, all of which block the whole cohort rather than the entry:
    /// an audit that observed slots and published no total; a total whose role
    /// breakdown does not add up to it; a census the preparation itself marked
    /// incomplete; and a total too large to carry into the ceiling arithmetic.
    /// The first is the important one - a missing counter must never read as the
    /// zero that would let every remaining entry launch.
    ///
    /// The unmeasured allowance is the one place a number is added that was
    /// not measured, and it is added in the safe direction: a slot interrupted
    /// mid-phase may have started models whose records it never published, and
    /// the reviewed side has already bounded how many from that run's own sealed
    /// plan. The ceiling is checked against the total plus that allowance.
    /// </remarks>
    private static (int Total, int Generalist, int Specialist, int Verifier, int UnmeasuredAllowance) RequireRealModelStarts(
        CohortEntry entry,
        JsonElement audit,
        string label)
    {
        var observed = audit.TryGetProperty("realModelStartsObserved", out var flag)
            && flag.ValueKind is JsonValueKind.True or JsonValueKind.False
            && flag.ValueKind == JsonValueKind.True;
        if (!observed)
        {
            // A preparation that supervised no slot started no model, and says so
            // by publishing the flag false. That is a reading, not an absence: the
            // flag itself is required below by the same code path that requires the
            // counters, because an audit missing both would otherwise be read as a
            // preparation that quietly did nothing.
            if (!audit.TryGetProperty("realModelStartsObserved", out _))
            {
                throw new CohortBlockedException(
                    $"The {label} publishes no 'realModelStartsObserved'. This build spends a cohort budget in real model starts and " +
                    "refuses an audit that does not say whether it counted any: an unread counter is not a zero.");
            }
            // Supervising no slot is only the same thing as starting no model when
            // no slot was LAUNCHED either. A preparation that authorized a launch
            // and then lost the child before it reached a durable ending may have
            // started models it can no longer account for, and that is a stop.
            var launched = RequireCounter(audit, "realModelStartLaunchedSlotCount", label);
            if (launched > 0)
            {
                throw new CohortBlockedException(
                    $"Entry '{entry.EntryId}' published an audit that launched {launched.ToString(CultureInfo.InvariantCulture)} slot(s) and " +
                    "supervised none of them to a durable ending, so what those launches spent is unknown rather than nothing. The cohort stops here.");
            }
            return (0, 0, 0, 0, 0);
        }
        var total = RequireCounter(audit, "realModelStartCount", label);
        var generalist = RequireCounter(audit, "realModelStartsGeneralist", label);
        var specialist = RequireCounter(audit, "realModelStartsSpecialist", label);
        var verifier = RequireCounter(audit, "realModelStartsVerifier", label);
        if (generalist + specialist + verifier != total)
        {
            throw new CohortBlockedException(
                $"The {label} reports {total.ToString(CultureInfo.InvariantCulture)} real model start(s) and a role breakdown summing to " +
                $"{(generalist + specialist + verifier).ToString(CultureInfo.InvariantCulture)}. A cohort stops rather than spend a budget against a census " +
                "whose parts contradict its total.");
        }
        if (!audit.TryGetProperty("realModelStartCensusComplete", out var complete) || complete.ValueKind != JsonValueKind.True)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' published an audit whose real model start census is not complete, so what it spent is unknown " +
                "rather than small. The cohort stops here instead of launching another entry against a budget it can no longer measure.");
        }
        var unmeasured = RequireCounter(audit, "realModelStartUnmeasuredAllowance", label);
        return (
            RequireRepresentable(total, "realModelStartCount", label),
            RequireRepresentable(generalist, "realModelStartsGeneralist", label),
            RequireRepresentable(specialist, "realModelStartsSpecialist", label),
            RequireRepresentable(verifier, "realModelStartsVerifier", label),
            RequireRepresentable(unmeasured, "realModelStartUnmeasuredAllowance", label));
    }

    /// <summary>
    /// A counter the budget rests on, read on the same terms as the write
    /// counters: absent, negative or unreadable is a refusal, never a zero.
    /// </summary>
    private static long RequireCounter(JsonElement parent, string name, string label)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            throw new CohortBlockedException(
                $"The {label} publishes no readable '{name}'. A cohort ceiling is only as good as the counter it is checked against, " +
                "and an unreadable counter is not a zero.");
        }
        if (!value.TryGetInt64(out var number) || number < 0)
        {
            throw new CohortBlockedException(
                $"The {label} publishes '{name}' as '{value.GetRawText()}', which is not a count this build can add up. " +
                "The cohort stops rather than treat it as nothing.");
        }
        return number;
    }

    /// <summary>
    /// Refuses an audit that does not match its own self-hash or its own
    /// signature.
    /// </summary>
    /// <remarks>
    /// The per-entry preparation self-hashes its audit and then signs it with the
    /// same key it signs its state record with, and that key sits in the entry's
    /// own output root. Recomputing both here is what makes the cohort index worth
    /// more than the sum of files that happened to be lying in the declared roots:
    /// without it, an index could be signed over readings that were edited after
    /// the preparation published them. The self-hash catches a careless edit; only
    /// the signature catches a careful one, because a careful editor recomputes
    /// the hash.
    ///
    /// This is not claimed as an adversary defence, for the same reason the
    /// single-run record does not claim it: the key sits beside the artifact under
    /// the same ownership. What it establishes is that the readings the cohort
    /// indexes are the readings its own preparations published.
    /// </remarks>
    private static void RequireAuthentic(CohortEntry entry, JsonElement audit, string path, string label)
    {
        var keyPath = StateKeyPathFor(entry);
        // Read once, not checked and then read: between an existence check and a
        // read the file can go, and a key that goes missing mid-check must be one
        // refusal naming the root, not a fault from underneath. The preparation's
        // own reader, over the preparation's own format - a cohort that read the
        // key its own way would be checking a signature against something other
        // than what signed it.
        byte[] key;
        try
        {
            key = CoordinatorState.ReadSigningKey(keyPath, "signing key");
        }
        catch (ContractException error)
        {
            throw new ContractException(
                $"The {label} at '{path}' stands in a root whose signing key could not be taken. {error.Message} " +
                "An audit whose key cannot be read cannot be shown to be the one that preparation published.");
        }

        var recordedSignature = StrictJson.RequireHex(audit, "signature", label, 64);
        var recordedSelfHash = StrictJson.RequireHex(audit, "auditSha256", label, 64);

        var node = (MapNode)Node.FromJson(audit, label);
        node.Remove("signature");
        var expectedSignature = CanonicalJson.HmacHex(key, CanonicalJson.Canonical(node));
        if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expectedSignature), Convert.FromHexString(recordedSignature)))
        {
            throw new ContractException(
                $"The {label} at '{path}' does not match its own signature; it was truncated or edited after it was written.");
        }

        node.Remove("auditSha256");
        var expectedSelfHash = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(node));
        if (!string.Equals(expectedSelfHash, recordedSelfHash, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} at '{path}' digests to {expectedSelfHash} and claims {recordedSelfHash}.");
        }
    }

    /// <summary>
    /// A total narrowed back to the width the journal and the ceiling arithmetic
    /// hold.
    /// </summary>
    /// <remarks>
    /// The model start count is consulted before every entry to decide whether
    /// the cohort may continue, so a total that wrapped to a negative number
    /// would not merely be wrong: it would read as consumption already spent in
    /// reverse and admit every remaining entry regardless of the ceiling. An
    /// unchecked cast is how that happens, so the narrowing is checked.
    /// </remarks>
    private static int RequireRepresentable(long total, string name, string label)
    {
        if (total < 0 || total > int.MaxValue)
        {
            throw new CohortBlockedException(
                $"The {label} totals '{name}' to {total.ToString(CultureInfo.InvariantCulture)}, which is not a count this build adds to a " +
                "cohort ceiling. A total that cannot be carried is refused rather than narrowed into a number that would disable the ceiling.");
        }
        return (int)total;
    }

    /// <summary>
    /// A counter the whole preview-only claim rests on. Unlike the descriptive
    /// counters below, this one is never read leniently: an absent, negative,
    /// fractional or unrepresentable write count would otherwise read as the zero
    /// the cohort is trying to prove, which is the one reading it must never be
    /// allowed to produce by accident.
    /// </summary>
    private static int RequireWriteCount(JsonElement parent, string name, string label)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            throw new CohortBlockedException(
                $"The {label} publishes no readable '{name}'. A cohort's zero-write claim is only as good as the counter it reads, " +
                "and an unreadable counter is not a zero.");
        }
        if (!value.TryGetInt32(out var number) || number < 0)
        {
            throw new CohortBlockedException(
                $"The {label} publishes '{name}' as '{value.GetRawText()}', which is not a count this build can add up. " +
                "The cohort stops rather than treat it as nothing.");
        }
        return number;
    }

    /// <summary>
    /// One definition of "wrote nothing", applied wherever a cohort reads a
    /// count. A build that wanted to permit a write would have to change this
    /// method.
    /// </summary>
    internal static void RequireZeroWrites(CohortEntry entry, int providerWrites, int writeInvocations)
    {
        if (providerWrites != 0 || writeInvocations != 0)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' published an audit reporting {providerWrites.ToString(CultureInfo.InvariantCulture)} provider write(s) and " +
                $"{writeInvocations.ToString(CultureInfo.InvariantCulture)} write tool invocation(s). This cohort is authorized preview-only and every " +
                "remaining entry is abandoned rather than run beside a preparation that wrote.")
            {
                ObservedProviderWriteCount = providerWrites,
                ObservedWriteToolInvocationCount = writeInvocations
            };
        }
    }

    /// <summary>
    /// One definition of "may not write", applied wherever a cohort reads a
    /// reported capability.
    /// </summary>
    internal static void RequireNoWriteCapability(CohortEntry entry, JsonElement audit, string label)
    {
        var kind = ReadText(audit, "deliveryAuthorizationKind");
        if (!string.Equals(kind, "none", StringComparison.Ordinal)
            && !string.Equals(kind, CohortExecution.PreviewOnlyKind, StringComparison.Ordinal))
        {
            throw new CohortBlockedException(
                $"The {label} reports authorization kind '{kind}'. A cohort runs one kind, '{CohortExecution.PreviewOnlyKind}', and it " +
                "stops entirely rather than continue beside a preparation that held another.");
        }
        foreach (var capability in new[] { "deliveryCommentsEnabled", "deliveryVotesEnabled", "deliveryGatesEnabled" })
        {
            if (audit.TryGetProperty(capability, out var value) && value.ValueKind == JsonValueKind.True)
            {
                throw new CohortBlockedException(
                    $"The {label} reports '{capability}' true. Every write capability is off in this build, so a cohort that observes one " +
                    "abandons every remaining entry rather than continue.");
            }
        }
    }

    /// <summary>The evidence digest each committed transition published, by state name.</summary>
    private static Dictionary<string, string> ReadTransitionDigests(JsonElement audit, string label)
    {
        var digests = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!audit.TryGetProperty("transitions", out var transitions) || transitions.ValueKind != JsonValueKind.Array)
        {
            throw new CohortBlockedException($"The {label} carries no transition list, so nothing in it can be indexed.");
        }
        foreach (var transition in transitions.EnumerateArray())
        {
            if (transition.ValueKind != JsonValueKind.Object)
            {
                continue;
            }
            if (!transition.TryGetProperty("state", out var state) || state.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            if (!transition.TryGetProperty("evidenceSha256", out var digest) || digest.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            digests[state.GetString()!] = digest.GetString()!;
        }
        return digests;
    }

    private static string DigestOf(Dictionary<string, string> digests, string state) =>
        digests.TryGetValue(state, out var value) ? value : "none";

    /// <summary>
    /// The reviewer processes each supervised slot reported having launched,
    /// added up. Diagnostic only: this is a census of PROCESSES, and a budget
    /// spent in model starts is never checked against it. It was once published
    /// under a name that suggested otherwise, which is how a two-slot entry that
    /// started four models came to be accounted as three.
    /// </summary>
    private static long SlotAttemptRecords(JsonElement audit)
    {
        if (!audit.TryGetProperty("slots", out var slots) || slots.ValueKind != JsonValueKind.Array)
        {
            return 0;
        }
        long total = 0;
        foreach (var slot in slots.EnumerateArray())
        {
            if (slot.ValueKind != JsonValueKind.Object)
            {
                continue;
            }
            total += ReadCount(slot, "slotAttemptRecordCount");
        }
        return total;
    }

    /// <summary>
    /// A counter the audit may or may not have observed. Absent reads as zero
    /// here and only here, because the audit publishes an explicit flag beside
    /// its own counters and a summary that refused to add up an unobserved count
    /// could never report a preparation that stopped early.
    /// </summary>
    private static long ReadCount(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            return 0;
        }
        return value.TryGetInt64(out var number) && number >= 0 ? number : 0;
    }

    private static string ReadText(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return "none";
        }
        var text = value.GetString();
        return string.IsNullOrEmpty(text) ? "none" : text;
    }
}

/// <summary>
/// The ordered, self-hashed, signed account of one cohort.
/// </summary>
/// <remarks>
/// Built entirely from the signed journal and the per-entry audits, never from
/// what a particular process happened to do, so it is rebuildable: pointing this
/// build at the same manifest with nothing left to run republishes byte-identical
/// content. The self-hash catches a careless edit; only the signature catches a
/// careful one, because a careful editor recomputes the hash.
/// </remarks>
/// <summary>
/// Decides whether an entry that ended with a non-zero exit nevertheless proved,
/// in its own authenticated audit, that it reached the state the cohort asked
/// for.
/// </summary>
/// <remarks>
/// This exists because of a real cohort. A preparation was told to stop the
/// moment it verified its delivery terminal - which is the target the cohort
/// declared - and it did exactly that: it verified the terminal, wrote its
/// evidence, wrote its ending, and exited 9 to say it had stopped on purpose.
/// The runner read only the exit code, called it a fault, and abandoned the two
/// entries behind it. Every artifact needed to see that the entry was finished
/// was on disk, signed, at the moment the decision was made.
///
/// So the exit code stops being the only witness. It is still a witness: an exit
/// this class does not recognise is never adopted, and neither is a zero-exit
/// entry, which needs no adoption. What is added is that the audit has to AGREE,
/// and the agreement is checked against artifacts rather than inferred:
///
///   - the audit is the entry's own, authenticated - the reader that produced
///     this summary already required its HMAC, its correlation, its request
///     digest and its subject digest to be the ones the manifest sealed, and
///     refused it otherwise;
///   - the state it reports at rest is the state the cohort declared as its
///     target, so a run halted EARLIER is never adopted no matter how it exited;
///   - it is at rest for a reason that means the walk chose to stop, rather than
///     one that means something went wrong;
///   - every transition the target implies published evidence, so a run that
///     claims the state without the artifacts behind it is refused;
///   - the signed state record still on disk is the one the audit was written
///     over, so an audit describing a root that has since moved on is refused;
///   - and nothing was written to the provider, which the cohort's budget says
///     is zero.
///
/// Nothing here reads a finding, a candidate, a verdict or a severity. The two
/// words it compares are the preparation's own closed vocabularies, and it
/// compares them to constants rather than interpreting them.
/// </remarks>
internal static class CohortCompletionAdoption
{
    /// <summary>The preparation stopped because it had nothing left to do.</summary>
    private const string ReasonCompleted = "completed";

    /// <summary>The preparation stopped because it had been told to stop here.</summary>
    private const string ReasonDeliberateHalt = "deliberateHalt";

    /// <summary>
    /// The non-zero exits an adoption may be considered for at all.
    /// </summary>
    /// <remarks>
    /// One code, and it is the code that means "stopped where you told me to".
    /// A contract refusal, a child failure, an unresolved launch or an
    /// unrecognised code all describe a preparation that did not choose its
    /// ending, and no audit written by one of them is evidence that it did.
    /// </remarks>
    internal static bool IsAdoptableExit(int exitCode) => exitCode == CoordinatorExitCodes.Halted;

    /// <summary>
    /// Whether this ended-but-not-complete entry proved completion, and the words
    /// for why it did or did not.
    /// </summary>
    internal static (bool Adopted, string Reason) Evaluate(CohortManifest manifest, CohortEntrySummary summary)
    {
        var record = summary.Record;
        if (!record.HasEnded || record.EndedRefused)
        {
            return (false, "the entry has no ending this runner committed");
        }
        if (record.ExitCode == CoordinatorExitCodes.Ok)
        {
            return (false, "the entry exited cleanly and needs no adoption");
        }
        if (!IsAdoptableExit(record.ExitCode))
        {
            return (false, $"the entry exited {record.ExitCode.ToString(CultureInfo.InvariantCulture)}, which is not an ending a preparation chooses");
        }

        var target = manifest.Execution.Target;
        if (!string.Equals(summary.PreparationFinalState, target, StringComparison.Ordinal))
        {
            return (false, $"its audit reports it at rest in '{summary.PreparationFinalState}' and the cohort asked for '{target}'");
        }
        if (!string.Equals(summary.PreparationTerminalReason, ReasonCompleted, StringComparison.Ordinal)
            && !string.Equals(summary.PreparationTerminalReason, ReasonDeliberateHalt, StringComparison.Ordinal))
        {
            return (false, $"its audit is at rest for '{summary.PreparationTerminalReason}', which is not a reason a walk chooses");
        }

        // Evidence is required by the rank the cohort asked for, not by the
        // deepest rank there is. A cohort declaring an earlier target is asking
        // for a shorter walk, and demanding a delivery digest of a walk that was
        // never asked to deliver would make adoption unreachable for it - refused
        // rather than wrong, but unreachable all the same. Each entry below is the
        // artifact a rank cannot have been reached without, and each threshold is
        // the rank of the transition that publishes that artifact: run-set
        // evidence IS the 'runSetReady' transition digest, so it is owed from
        // PreparationRank rather than from the first slot's terminal.
        //
        // The snapshot digest is the one exception: it is required at every rank,
        // which makes adoption unreachable for a target below 'snapshotVerified'.
        // That is deliberate. No cohort has ever declared a corpus-stage target,
        // and an adoption resting on no published transition digest at all would
        // rest on the audit's own word for where it stopped.
        var rank = PreparationStateNames.RankOf(PreparationStateNames.Parse(target));
        var required = new List<(string Name, string Digest)>
        {
            ("snapshot evidence", summary.SnapshotEvidenceSha256)
        };
        if (rank >= PreparationStateNames.PreparationRank)
        {
            required.Add(("run set evidence", summary.RunSetEvidenceSha256));
        }
        if (rank >= PreparationStateNames.ReconciliationRank)
        {
            required.Add(("reconciliation evidence", summary.ReconciliationEvidenceSha256));
            required.Add(("reconciliation", summary.ReconciliationSha256));
            required.Add(("reconciliation report", summary.ReconciliationReportSha256));
        }
        if (rank >= PreparationStateNames.DeliveryRank)
        {
            required.Add(("delivery evidence", summary.DeliveryEvidenceSha256));
            required.Add(("delivery decision", summary.DeliveryDecisionSha256));
            required.Add(("delivery summary", summary.DeliverySummarySha256));
        }
        foreach (var (name, digest) in required)
        {
            if (!StrictJson.IsLowerHex(digest) || digest.Length != 64)
            {
                return (false, $"its audit publishes no {name} digest, so the state it claims stands on nothing");
            }
        }

        if (summary.ProviderWriteCount > manifest.Budgets.ProviderWriteBudget
            || summary.WriteToolInvocationCount > manifest.Budgets.ProviderWriteBudget)
        {
            return (false, "its audit reports a provider write, and a cohort that wrote is never adopted as complete");
        }

        if (!StrictJson.IsLowerHex(summary.StateSha256) || summary.StateSha256.Length != 64)
        {
            return (false, "its audit publishes no state record digest, so the state it claims stands on nothing");
        }

        var statePath = Path.Combine(summary.Entry.OutputRoot, "coordinator", "state.json");
        if (!File.Exists(statePath))
        {
            return (false, "its output root holds no state record for the audit to have been written over");
        }
        string standing;
        try
        {
            standing = CanonicalJson.Sha256Hex(
                StrictJson.ReadFileBytes(statePath, $"entry '{summary.Entry.EntryId}' state record", 64L * 1024 * 1024));
        }
        catch (ContractException error)
        {
            return (false, $"its signed state record could not be read ({error.Message})");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (false, $"its signed state record could not be read ({error.GetType().Name})");
        }
        if (!string.Equals(standing, summary.StateSha256, StringComparison.Ordinal))
        {
            return (false, "its audit was written over a state record other than the one now standing in its output root");
        }

        return (true, $"its authenticated audit reports '{target}' reached and at rest for '{summary.PreparationTerminalReason}' with every transition's evidence published and no provider write");
    }
}

internal static class CohortIndex
{
    internal const string ContractVersionValue = "devpilot.shadow-cohort.index.v2";
    internal const string KindValue = "shadow-cohort-index";

    /// <summary>The reviewed plan's own word for the posture, unchanged by scaling it across a set.</summary>
    internal const string PreviewOnlyMode = "previewOnly";

    /// <summary>Why a cohort is at rest, in a closed vocabulary.</summary>
    internal const string ReasonRunning = "running";

    internal const string ReasonCompleted = "completed";

    /// <summary>Every declared entry was reached and at least one ended other than complete.</summary>
    /// <remarks>
    /// Distinct from stopping on a failure, and the distinction is the whole
    /// difference between the two stop policies: this word says the set was walked
    /// to its end anyway. It is a count of endings, not an opinion about them.
    /// </remarks>
    internal const string ReasonCompletedWithFailure = "completedWithEntryFailure";

    internal const string ReasonStoppedOnFailure = "stoppedOnEntryFailure";

    internal const string ReasonBudgetExhausted = "budgetExhausted";

    /// <summary>
    /// The cohort had already spent more than its ceiling allowed.
    /// </summary>
    /// <remarks>
    /// Distinct from an exhausted budget on purpose. 'Exhausted' is the healthy
    /// stop: the next entry's sealed estimate would not fit, so it is not
    /// started. 'Exceeded' is the unhealthy one: an entry that has ALREADY run
    /// turned out to cost more than the whole set was allowed, which means an
    /// estimate was wrong or an audit reported more than its bound admitted. The
    /// entry's own result stands either way, and no further entry is launched -
    /// but an operator reading the index needs to be able to tell the two apart.
    /// </remarks>
    internal const string ReasonBudgetExceeded = "budgetExceeded";

    internal const string ReasonBlocked = "blocked";

    internal const string ReasonUnresolvedLaunch = "unresolvedLaunch";

    internal const string ReasonContractRefusal = "contractRefusal";

    internal const string ReasonUnexpectedFault = "unexpectedFault";

    /// <summary>
    /// Every word this build publishes about a cohort at rest, and the only ones
    /// its signed journal admits.
    /// </summary>
    /// <remarks>
    /// The journal carries the published word so a rebuild reproduces it rather
    /// than inferring it, and a journal that carried a word this build does not
    /// know would produce an index nobody could compare with anything. The list
    /// is closed here rather than at each writer so the two can never drift.
    /// </remarks>
    private static readonly string[] Reasons =
    [
        ReasonRunning,
        ReasonCompleted,
        ReasonCompletedWithFailure,
        ReasonStoppedOnFailure,
        ReasonBudgetExhausted,
        ReasonBudgetExceeded,
        ReasonBlocked,
        ReasonUnresolvedLaunch,
        ReasonContractRefusal,
        ReasonUnexpectedFault
    ];

    internal static bool IsKnownReason(string reason) => Array.IndexOf(Reasons, reason) >= 0;

    internal static void Publish(
        CohortManifest manifest,
        CohortJournal journal,
        byte[] key,
        IReadOnlyList<CohortEntrySummary> summaries,
        string terminalReason,
        string terminalDetail,
        string terminalDetailSha256)
    {
        var entries = new ListNode();
        long models = 0;
        long verifiers = 0;
        long seconds = 0;
        long writes = 0;
        var completed = 0;
        var pending = 0;
        var adoptedOrdinals = new ListNode();
        foreach (var summary in summaries)
        {
            entries.Add(summary.Describe());
            models += summary.ModelStartCount;
            verifiers += summary.VerifierAssignmentCount;
            seconds += summary.WallClockSeconds;
            writes += summary.ProviderWriteCount;
            if (summary.Record.EndedComplete)
            {
                // Complete in the journal AND non-zero on the way out is an entry
                // this build adopted. The journal's word is not enough on its own:
                // a record saying "complete" beside artifacts that no longer prove
                // it is exactly the shape a rebuild exists to catch, so the proof
                // is re-run here rather than inherited. Published as an ordinal
                // rather than as an identifier, because an identifier can carry a
                // subject.
                if (summary.Record.HasEnded && summary.Record.ExitCode != CoordinatorExitCodes.Ok)
                {
                    var (adopted, reason) = CohortCompletionAdoption.Evaluate(manifest, summary);
                    if (!adopted)
                    {
                        throw new CohortBlockedException(
                            $"Entry {summary.Entry.Ordinal.ToString(CultureInfo.InvariantCulture)} is recorded complete after exiting " +
                            $"{summary.Record.ExitCode.ToString(CultureInfo.InvariantCulture)}, and this build cannot reproduce the proof it was " +
                            $"adopted on: {reason}. An index that published a completion it could not re-derive would be a record standing on " +
                            "artifacts that no longer say what it says.");
                    }
                    adoptedOrdinals.Add(Node.Number(summary.Entry.Ordinal));
                }
                completed++;
            }
            else if (CohortCompletionAdoption.Evaluate(manifest, summary).Adopted)
            {
                // A root written by an earlier build, whose journal recorded the
                // exit code and called it a fault. The artifacts say otherwise and
                // the artifacts are signed, so the count says what the artifacts
                // say. The per-entry summary is left exactly as it was committed:
                // it is digest-bound to the journal, and an index that rewrote it
                // would be an index that could no longer be checked against the
                // record it was derived from.
                completed++;
                adoptedOrdinals.Add(Node.Number(summary.Entry.Ordinal));
            }
            if (!summary.Record.HasEnded)
            {
                pending++;
            }
        }

        var index = new MapNode()
            .Set("contractVersion", ContractVersionValue)
            .Set("kind", KindValue)
            .Set("cohortId", manifest.CohortId)
            .Set("correlationId", manifest.CorrelationId)
            .Set("manifestSha256", manifest.ManifestSha256)
            .Set("bindingSha256", journal.BindingSha256)
            .Set("toolkitHead", manifest.ToolkitHead)
            .Set("concurrency", manifest.Execution.Concurrency)
            .Set("stopPolicy", manifest.Execution.StopPolicy)
            .Set("authorizationKind", manifest.Execution.AuthorizationKind)
            .Set("deliveryMode", PreviewOnlyMode)
            .Set("declaredEntryCount", manifest.Entries.Count)
            .Set("completedEntryCount", completed)
            .Set("adoptedCompleteEntryOrdinals", adoptedOrdinals)
            .Set("pendingEntryCount", pending)
            .Set("budgets", manifest.Budgets.Describe())
            .Set("consumed", new MapNode()
                .Set("modelStarts", models)
                .Set("verifierAssignments", verifiers)
                .Set("wallClockSeconds", seconds)
                .Set("providerWrites", writes))
            .Set("entries", entries)
            .Set("journalSequence", journal.Sequence)
            .Set("journalSha256", JournalDigest(manifest.JournalPath))
            .Set("terminalReason", terminalReason)
            .Set("terminalDetail", terminalDetail)
            // A refusal's own words can name the path it refused, and an entry's
            // output root can encode the subject it was taken over. So the words
            // go to the runner's log, where an operator reads them, and the index
            // carries only their digest - which ties the two together without
            // publishing either.
            .Set("terminalDetailSha256", terminalDetailSha256);
        index.Set("indexSha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(index)));
        index.Set("signature", CanonicalJson.HmacHex(key, CanonicalJson.Canonical(index)));
        var parent = Path.GetDirectoryName(manifest.IndexPath);
        if (!string.IsNullOrEmpty(parent))
        {
            Directory.CreateDirectory(parent);
        }
        CanonicalJson.WriteFileAtomic(manifest.IndexPath, CanonicalJson.Readable(index));
    }

    /// <summary>
    /// The digest of the journal this index was derived from, or the word for
    /// there being no journal yet.
    /// </summary>
    /// <remarks>
    /// Read through the same guard every other artifact is read through. A
    /// journal that cannot be opened is not a failure to write the index, and it
    /// must not arrive at the caller as one: the lenient handler above exists for
    /// an index that could not be written, and a journal nobody could read
    /// arriving there would be reported as a cohort that carried on.
    /// </remarks>
    private static string JournalDigest(string journalPath) =>
        File.Exists(journalPath)
            ? CanonicalJson.Sha256Hex(StrictJson.ReadFileBytes(journalPath, "cohort journal"))
            : "none";
}
