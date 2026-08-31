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
/// <summary>
/// One reciprocal verifier model and the number of assignments an entry stood on
/// against it.
/// </summary>
/// <remarks>
/// The model name is carried verbatim as the opaque request string it is. No
/// line in this program compares it to anything or reads any meaning from it;
/// it exists so an operator can see that a census of forty was two models of
/// twenty rather than one model of forty.
/// </remarks>
internal readonly record struct VerifierModelAssignments(string VerifierModel, int AssignmentCount);

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

    /// <summary>
    /// THE unit a cohort's verifier ceiling is spent in: one candidate paired
    /// with one required reciprocal model, counted from the entry's own sealed
    /// per-slot preview manifests. Not a count of terminal states, which is what
    /// scored a forty-assignment entry as four.
    /// </summary>
    internal required int VerifierAssignmentCount { get; init; }

    /// <summary>
    /// Assignments an interrupted entry may have been given and could not seal,
    /// bounded on the reviewed side against that run's own plan. The ceiling is
    /// checked against the measured total plus this.
    /// </summary>
    internal required int VerifierAssignmentUnmeasuredAllowance { get; init; }

    /// <summary>
    /// The same census broken down by reciprocal model. Opaque: the model names
    /// are request strings this program never reads for meaning.
    /// </summary>
    internal required IReadOnlyList<VerifierModelAssignments> VerifierAssignmentsByModel { get; init; }

    /// <summary>
    /// Grouped verifier subprocess launches. Diagnostic only - one process can
    /// serve a cluster of assignments, so a ceiling spent in these would shrink
    /// whenever grouping worked.
    /// </summary>
    internal required int VerifierProcessStartCount { get; init; }

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
            .Set("verifierAssignmentUnmeasuredAllowance", VerifierAssignmentUnmeasuredAllowance)
            .Set("verifierAssignmentsByModel", DescribeAssignmentsByModel())
            .Set("verifierProcessStartCount", VerifierProcessStartCount)
            .Set("providerWriteCount", ProviderWriteCount)
            .Set("writeToolInvocationCount", WriteToolInvocationCount)
            .Set("wallClockSeconds", WallClockSeconds)
            .Set("deliveryMode", CohortIndex.PreviewOnlyMode);
        summary.Set("summarySha256", CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(summary)));
        return summary;
    }

    private ListNode DescribeAssignmentsByModel()
    {
        var rows = new ListNode();
        foreach (var row in VerifierAssignmentsByModel)
        {
            rows.Add(new MapNode().Set("verifierModel", row.VerifierModel).Set("assignmentCount", row.AssignmentCount));
        }
        return rows;
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
        VerifierAssignmentUnmeasuredAllowance = 0,
        VerifierAssignmentsByModel = [],
        VerifierProcessStartCount = 0,
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
    /// Reads one entry's signed preparation audit into the opaque summary the
    /// cohort index publishes.
    /// </summary>
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

        var providerWrites = RequireWriteCount(audit, "providerWriteCount", label);
        var writeInvocations = RequireWriteCount(audit, "writeToolInvocations", label);
        RequireZeroWrites(entry, providerWrites, writeInvocations);
        RequireNoWriteCapability(entry, audit, label);
        RequireEnded(entry, audit, label);
        var starts = RequireRealModelStarts(entry, audit, label);
        var assignments = RequireRealVerifierAssignments(entry, audit, label, starts.Verifier);

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
            VerifierAssignmentCount = assignments.Total,
            VerifierAssignmentUnmeasuredAllowance = assignments.UnmeasuredAllowance,
            VerifierAssignmentsByModel = assignments.ByModel,
            VerifierProcessStartCount = assignments.ProcessStarts,
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
    /// The real cross-verifier assignments one entry stood on, read from its own
    /// signed audit and refused rather than guessed.
    /// </summary>
    /// <remarks>
    /// THE number a cohort's verifier ceiling is spent in, and a different unit
    /// from a model start. One assignment is one candidate paired with one
    /// required reciprocal model; the reviewed side mints an identity per pair
    /// and seals them in its per-slot preview manifests, which is what this
    /// reads through. The defect this replaced counted committed terminal
    /// transitions instead, so an entry that stood on forty assignments was
    /// accounted as four and could never have been accounted as more than eight.
    ///
    /// Grouped verifier PROCESS starts are read alongside and published as a
    /// diagnostic only. They are deliberately not the ceiling's unit: one
    /// subprocess can verify a whole cluster, so a budget spent in processes
    /// would shrink every time grouping worked.
    ///
    /// The cross-check against the model-start census is one-sided on purpose.
    /// Grouping and retries make the two disagree in either direction, so
    /// equality is never required; but an entry cannot have started a verifier
    /// process without an assignment for it to serve, and an audit reporting that
    /// contradicts itself.
    /// </remarks>
    private static (int Total, int UnmeasuredAllowance, int ProcessStarts, IReadOnlyList<VerifierModelAssignments> ByModel)
        RequireRealVerifierAssignments(CohortEntry entry, JsonElement audit, string label, int verifierModelStarts)
    {
        if (!audit.TryGetProperty("realVerifierAssignmentsObserved", out var flag)
            || flag.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new CohortBlockedException(
                $"The {label} publishes no 'realVerifierAssignmentsObserved'. This build spends a cohort's verifier ceiling in real " +
                "cross-verifier assignments and refuses an audit that does not say whether it counted any: an unread counter is not a " +
                "zero, and the audit of an entry that stood on forty assignments and cannot say so must not be scored as four.");
        }
        if (flag.ValueKind != JsonValueKind.True)
        {
            // Supervising no slot is only the same as standing on no assignment
            // when no slot was launched either, on exactly the terms the model
            // start census applies.
            var launched = RequireCounter(audit, "realModelStartLaunchedSlotCount", label);
            if (launched > 0)
            {
                throw new CohortBlockedException(
                    $"Entry '{entry.EntryId}' published an audit that launched {launched.ToString(CultureInfo.InvariantCulture)} slot(s) and " +
                    "supervised none of them to a durable ending, so the verifier assignments those launches stood on are unknown rather " +
                    "than nothing. The cohort stops here.");
            }
            return (0, 0, 0, []);
        }
        var total = RequireCounter(audit, "realVerifierAssignmentCount", label);
        var processStarts = RequireCounter(audit, "verifierProcessStartCount", label);
        if (!audit.TryGetProperty("realVerifierAssignmentCensusComplete", out var complete) || complete.ValueKind != JsonValueKind.True)
        {
            throw new CohortBlockedException(
                $"Entry '{entry.EntryId}' published an audit whose real verifier assignment census is not complete, so what it stood on " +
                "is unknown rather than small. The cohort stops here instead of launching another entry against a ceiling it can no " +
                "longer measure.");
        }
        var unmeasured = RequireCounter(audit, "realVerifierAssignmentUnmeasuredAllowance", label);
        var byModel = ReadVerifierAssignmentsByModel(audit, label, total);
        if (total == 0 && processStarts > 0)
        {
            throw new CohortBlockedException(
                $"The {label} reports {processStarts.ToString(CultureInfo.InvariantCulture)} verifier process start(s) and no assignment " +
                "at all. A verifier subprocess exists to serve assignments, so those two halves of the census contradict each other and " +
                "the cohort stops rather than spend a ceiling against either.");
        }
        if (total == 0 && verifierModelStarts > 0)
        {
            throw new CohortBlockedException(
                $"The {label} reports {verifierModelStarts.ToString(CultureInfo.InvariantCulture)} real model start(s) in the verifier role " +
                "and no verifier assignment at all. Those two censuses are taken over the same phase of the same run and contradict each " +
                "other, so the cohort stops here.");
        }
        // Deliberately no ordering between the two. Grouping puts launches below
        // assignments within a pass and a repeated verification of the same
        // candidates puts them above across passes, because identities dedupe
        // and launch nonces do not.
        return (
            RequireRepresentable(total, "realVerifierAssignmentCount", label),
            RequireRepresentable(unmeasured, "realVerifierAssignmentUnmeasuredAllowance", label),
            RequireRepresentable(processStarts, "verifierProcessStartCount", label),
            byModel);
    }

    /// <summary>
    /// The per-model assignment breakdown, refused unless it accounts for the
    /// total it is published beside.
    /// </summary>
    private static IReadOnlyList<VerifierModelAssignments> ReadVerifierAssignmentsByModel(JsonElement audit, string label, long total)
    {
        if (!audit.TryGetProperty("realVerifierAssignmentsByModel", out var byModel) || byModel.ValueKind != JsonValueKind.Array)
        {
            throw new CohortBlockedException(
                $"The {label} publishes no readable 'realVerifierAssignmentsByModel'. A verifier census this build cannot break down is " +
                "one it will not spend a ceiling against.");
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var rows = new List<VerifierModelAssignments>();
        long sum = 0;
        foreach (var entry in byModel.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object)
            {
                throw new CohortBlockedException($"The {label} breaks its verifier assignments down by an element that is not an object.");
            }
            var model = StrictJson.RequireString(entry, "verifierModel", label);
            if (!seen.Add(model))
            {
                throw new CohortBlockedException(
                    $"The {label} breaks its verifier assignments down by a model it names twice, so the breakdown is ambiguous and the cohort stops.");
            }
            var count = RequireCounter(entry, "assignmentCount", label);
            sum += count;
            rows.Add(new VerifierModelAssignments(model, RequireRepresentable(count, "assignmentCount", label)));
        }
        if (sum != total)
        {
            throw new CohortBlockedException(
                $"The {label} reports {total.ToString(CultureInfo.InvariantCulture)} verifier assignment(s) and a per-model breakdown " +
                $"summing to {sum.ToString(CultureInfo.InvariantCulture)}. The cohort stops rather than spend a ceiling against a census " +
                "whose parts contradict its total.");
        }
        return rows;
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
    /// <summary>
    /// How a completion that a previous build published stands when this build
    /// re-derives it.
    /// </summary>
    internal enum CompletionStanding
    {
        /// <summary>The proof re-ran and reproduced.</summary>
        Adopted,

        /// <summary>
        /// The proof cannot be re-run because the journal predates the witness it
        /// would rest on, and nothing else about the record contradicts it.
        /// </summary>
        DroppedUnwitnessed,

        /// <summary>The record and the artifacts disagree.</summary>
        Blocked
    }

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
    /// Whether this record predates the pre-adoption drain witness entirely, as
    /// opposed to positively recording that the witness was not obtained.
    /// </summary>
    /// <remarks>
    /// The distinction decides whether a completion this build cannot re-derive
    /// is a contradiction or an absence. 'timedOut' and 'abandoned' are a build
    /// SAYING the tree was never confirmed stopped, and a completion published
    /// over one of those is a record disagreeing with itself. 'none' is a build
    /// that never had the field: nothing disagrees, the proof simply is not
    /// there to re-run. Blocking on that would wedge the index forever, because
    /// the journal is signed and no operator can add the missing witness.
    /// </remarks>
    internal static bool IsUnwitnessedByAge(CohortEntryRecord record)
        => string.Equals(record.PreAdoptionOutcome, "none", StringComparison.Ordinal);

    /// <summary>
    /// Whether this ended-but-not-complete entry proved completion, and the words
    /// for why it did or did not.
    /// </summary>
    internal static (bool Adopted, string Reason) Evaluate(CohortManifest manifest, CohortEntrySummary summary)
        => Evaluate(manifest, summary, requireWitness: true);

    /// <summary>
    /// How a completion this build did not itself publish stands when the index
    /// is rebuilt: re-proved, dropped because the proof was never recorded, or
    /// blocked because the record and the artifacts disagree.
    /// </summary>
    /// <remarks>
    /// Only the third is a stop. A journal from a build that never recorded the
    /// pre-adoption witness cannot re-derive its completions and cannot be
    /// repaired either, so treating that as a contradiction would end every
    /// future run over that root. The completion is dropped instead - counted as
    /// not complete, published, and left to the walk's own stop policy - which
    /// is the loss the witness was always going to cost such journals.
    /// </remarks>
    internal static (CompletionStanding Standing, string Reason) Classify(CohortManifest manifest, CohortEntrySummary summary)
    {
        var (adopted, reason) = Evaluate(manifest, summary);
        if (adopted)
        {
            return (CompletionStanding.Adopted, reason);
        }
        if (!IsUnwitnessedByAge(summary.Record))
        {
            return (CompletionStanding.Blocked, reason);
        }
        // Everything EXCEPT the witness has to still reproduce. A record that is
        // both unwitnessed and contradicted by its artifacts is the tamper case,
        // and it blocks on the contradiction rather than being excused by its age.
        var (otherwiseAdoptable, otherReason) = Evaluate(manifest, summary, requireWitness: false);
        return otherwiseAdoptable
            ? (CompletionStanding.DroppedUnwitnessed, reason)
            : (CompletionStanding.Blocked, otherReason);
    }

    private static (bool Adopted, string Reason) Evaluate(CohortManifest manifest, CohortEntrySummary summary, bool requireWitness)
    {
        var record = summary.Record;
        if (!record.HasEnded || record.EndedRefused)
        {
            return (false, "the entry has no ending this runner committed");
        }
        // The recorded PRE-ADOPTION outcome must positively witness that the
        // supervised run drained to EOF and its process tree was confirmed
        // stopped. Adoption overwrites Outcome with 'complete', so Outcome alone
        // cannot tell an adoption that rested on a confirmed-stopped tree from one
        // that never had that witness - a record from a build that did not persist
        // the pre-adoption ending carries only the word 'complete', and reading
        // that as proof would re-adopt an entry whose descendant may still be
        // spending. 'timedOut' and 'abandoned' are the runner's durable record
        // that the witness was NOT obtained, and 'none' is a record that never
        // captured one; none of them is adopted over an otherwise-adoptable audit,
        // and the not-adopted outcome the runner already committed stands as the
        // durable ending. Reading the persisted witness rather than the exit code
        // closes both the live path and a later rebuild: an exited-but-not-drained
        // entry can carry an adoptable exit code, and only this field records that
        // its tree was never confirmed stopped.
        if (!CohortEntryOutcomes.IsDrainWitnessed(record.PreAdoptionOutcome) && requireWitness)
        {
            return (false, $"the entry's pre-adoption ending is recorded '{record.PreAdoptionOutcome}', an ending reached without confirming its output drained and its process tree stopped, so it is not adopted as complete");
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

    /// <summary>
    /// Proves an entry whose tree was never confirmed stopped is not adopted as
    /// complete over an otherwise-adoptable audit. Returns 0 when every check
    /// holds.
    /// </summary>
    /// <remarks>
    /// The one variable across the first four checks is the pre-adoption ending.
    /// Everything else - the adoptable exit code, the target at rest for a chosen
    /// reason, every required transition digest, the on-disk state record the audit
    /// was written over, and no provider write - is held fixed and adoptable. So a
    /// 'runNotComplete' pre-adoption ending (a typed coordinator terminal reached
    /// after the run drained to EOF) IS adopted. A generic 'preparationFaulted'
    /// ending is NOT: its exit does not contractually account the coordinator's own
    /// children. 'abandoned' and 'timedOut' are likewise refused. The fifth check
    /// holds the audit adoptable too but
    /// carries an Outcome already overwritten to 'complete' with no persisted
    /// pre-adoption ending ('none'), as a build that did not record the witness
    /// would have left it; it must not be adopted on the word 'complete' alone.
    /// While the gate read Outcome rather than the pre-adoption ending, the unsafe
    /// endings were adopted and the fifth record was re-adopted.
    /// </remarks>
    internal static int SelfTest(string root, TextWriter log)
    {
        Directory.CreateDirectory(root);
        var failures = 0;
        var checks = 0;

        // Every check this selftest declares. A pass that skipped one and still
        // said nothing failed would be a green that covered less than it claims,
        // so the count is asserted against this before the summary is printed.
        const int declaredChecks = 24;

        void Check(bool ok, string message)
        {
            checks++;
            log.WriteLine((ok ? "  PASS  " : "  FAIL  ") + message);
            if (!ok)
            {
                failures++;
            }
        }

        log.WriteLine("Completion adoption");

        var outputRoot = Path.Combine(root, "entry-root");
        Directory.CreateDirectory(Path.Combine(outputRoot, "coordinator"));
        var stateBytes = StrictJson.StrictUtf8.GetBytes("{\"state\":\"snapshotVerified\"}");
        var statePath = Path.Combine(outputRoot, "coordinator", "state.json");
        File.WriteAllBytes(statePath, stateBytes);
        var stateSha = CanonicalJson.Sha256Hex(stateBytes);
        var digest = new string('a', 64);
        const string target = "snapshotVerified";

        var entry = new CohortEntry
        {
            Ordinal = 1,
            EntryId = "entry-adoption",
            RequestPath = Path.Combine(root, "request.json"),
            RequestSha256 = digest,
            OutputRoot = outputRoot,
            Organization = "org",
            Project = "project",
            Repository = "repo",
            PullRequestId = 1,
            IterationId = 1,
            SourceCommit = new string('0', 40),
            CommonCommit = new string('0', 40),
            TargetCommit = new string('0', 40),
            TargetRefName = "refs/heads/main",
            ConfigSha256 = digest,
            PromptSha256 = digest,
            SchemaSha256 = digest,
            RuleBundleSourceKind = "inline",
            RuleBundlePath = Path.Combine(root, "rules"),
            RuleBundleSha256 = digest,
            EstimatedModelStarts = 0,
            ModelStartBoundPath = Path.Combine(root, "bound.json"),
            ModelStartBoundSha256 = digest,
            EstimatedVerifierAssignments = 0,
            EstimatedWallClockSeconds = 1
        };

        var execution = new CohortExecution
        {
            Concurrency = 1,
            StopPolicy = CohortManifest.StopPolicyContinue,
            AuthorizationKind = CohortExecution.PreviewOnlyKind,
            CommandPath = "stub.ps1",
            ArgumentPrefix = Array.Empty<string>(),
            RefusedArguments = Array.Empty<string>(),
            NamesShippingPreparation = false,
            NamesStubAdapter = true,
            IsShippingLaunchProfile = false,
            Target = target,
            EntryTimeoutSeconds = 60
        };

        var budgets = new CohortBudgets
        {
            MaximumPullRequests = 1,
            MaximumModelStarts = 0,
            MaximumVerifierAssignments = 0,
            MaximumWallClockSeconds = 1,
            ProviderWriteBudget = 0
        };

        var manifest = new CohortManifest
        {
            CohortId = "cohort-adoption",
            CorrelationId = "correlation-adoption",
            Kind = CohortManifest.KindValue,
            ToolkitRoot = root,
            ToolkitHead = new string('0', 40),
            RequiredRef = "refs/heads/main",
            Execution = execution,
            Budgets = budgets,
            JournalRoot = Path.Combine(root, "journal"),
            IndexPath = Path.Combine(root, "index.json"),
            Entries = new[] { entry },
            ManifestSha256 = digest
        };

        CohortEntrySummary SummaryWith(string outcome)
        {
            var record = CohortEntryRecord.Fresh(entry) with
            {
                State = CohortEntryStates.Ended,
                EndedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                ExitCode = CoordinatorExitCodes.Halted,
                Outcome = outcome,
                // These records are built as the runner would commit them before
                // any adoption, so the pre-adoption ending IS the outcome given.
                PreAdoptionOutcome = outcome
            };
            return new CohortEntrySummary
            {
                Entry = entry,
                Record = record,
                PreparationFinalState = target,
                PreparationTerminalReason = "deliberateHalt",
                SnapshotEvidenceSha256 = digest,
                RunSetEvidenceSha256 = digest,
                ReconciliationEvidenceSha256 = digest,
                DeliveryEvidenceSha256 = digest,
                ReconciliationSha256 = digest,
                ReconciliationReportSha256 = digest,
                DeliveryDecisionSha256 = digest,
                DeliverySummarySha256 = digest,
                AuditSha256 = digest,
                StateSha256 = stateSha,
                ModelStartCount = 0,
                ModelStartsGeneralist = 0,
                ModelStartsSpecialist = 0,
                ModelStartsVerifier = 0,
                ModelStartUnmeasuredAllowance = 0,
                SlotAttemptRecordCount = 0,
                SlotLaunchCount = 0,
                SupervisedSlotCount = 0,
                VerifierAssignmentCount = 0,
                VerifierAssignmentUnmeasuredAllowance = 0,
                VerifierAssignmentsByModel = Array.Empty<VerifierModelAssignments>(),
                VerifierProcessStartCount = 0,
                ProviderWriteCount = 0,
                WriteToolInvocationCount = 0,
                WallClockSeconds = 0
            };
        }

        // Control: with the tree confirmed stopped (a drain-witnessed outcome),
        // the fixed audit IS adoptable. This proves the summary below is genuinely
        // adoptable, so the two refusals that follow turn on the outcome alone.
        var (witnessedAdopted, witnessedWhy) = Evaluate(manifest, SummaryWith(CohortEntryOutcomes.RunNotComplete));
        Check(witnessedAdopted, $"a typed, drain-witnessed 'runNotComplete' with an adoptable audit is adopted ({witnessedWhy})");

        // A preparation fault may have happened before its own child supervisor
        // accounted for every descendant. Even an otherwise-adoptable audit cannot
        // turn that uncertain custody into completion.
        var (faultedAdopted, genericFaultWhy) = Evaluate(manifest, SummaryWith(CohortEntryOutcomes.PreparationFaulted));
        Check(!faultedAdopted, $"a generic 'preparationFaulted' entry is not adopted as complete ({genericFaultWhy})");

        // The defect: an entry recorded 'abandoned' - its own process exited but a
        // descendant outlived it holding the pipes - carries the same adoptable
        // exit code and the same adoptable audit. It must NOT be adopted, because
        // the descendant may still be spending against the output root.
        var (abandonedAdopted, abandonedWhy) = Evaluate(manifest, SummaryWith(CohortEntryOutcomes.Abandoned));
        Check(!abandonedAdopted, $"an 'abandoned' entry is not adopted as complete ({abandonedWhy})");

        // The same for a killed-on-timeout tree, whose stop was likewise never
        // confirmed.
        var (timedOutAdopted, timedOutWhy) = Evaluate(manifest, SummaryWith(CohortEntryOutcomes.TimedOut));
        Check(!timedOutAdopted, $"a 'timedOut' entry is not adopted as complete ({timedOutWhy})");
        Check(
            string.Equals(
                CohortRunner.ClassifyTimedOutPreparation(rootExited: true, outputClosed: true),
                CohortEntryOutcomes.Abandoned,
                StringComparison.Ordinal),
            "root exit plus inherited-pipe EOF remains abandoned without OS-enforced descendant containment");

        // A record a build that did not persist the pre-adoption ending could have
        // committed: its outcome was overwritten to 'complete' when it was adopted,
        // it still carries the adoptable exit code, and its pre-adoption ending is
        // absent, which reads as 'none'. Reading the word 'complete' as proof of a
        // drained, stopped tree is the exact gap this closes - the entry is not
        // adopted again, because 'none' is not a drain witness. Against the earlier
        // logic that read Outcome instead of the pre-adoption ending, 'complete'
        // passed and this entry was re-adopted.
        var legacyAdopted = CohortEntryRecord.Fresh(entry) with
        {
            State = CohortEntryStates.Ended,
            EndedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
            ExitCode = CoordinatorExitCodes.Halted,
            Outcome = CohortEntryOutcomes.Complete
            // PreAdoptionOutcome stays at Fresh's 'none': the witness this build
            // persists was never recorded by the one that wrote this entry.
        };
        var legacySummary = SummaryWith(CohortEntryOutcomes.Complete) with { Record = legacyAdopted };
        var (legacyReadopted, legacyWhy) = Evaluate(manifest, legacySummary);
        Check(!legacyReadopted, $"a 'complete' record with no persisted drain witness is not adopted as complete ({legacyWhy})");

        // Compatibility, stated as a property of the bytes rather than as a hope:
        // a journal signed by a build that never knew about the pre-adoption
        // ending is re-signed at load from this build's composition. If the field
        // were emitted unconditionally, every such journal would authenticate to a
        // different signature and be refused as tampered - unrepairably, because
        // the operator cannot re-sign it. Emitting it only when it holds a real
        // witness makes its presence the version marker and leaves the older
        // bytes byte-for-byte reproducible.
        var legacyComposed = CanonicalJson.Canonical(legacyAdopted.Describe());
        Check(!legacyComposed.Contains("preAdoptionOutcome", StringComparison.Ordinal),
            "a record with no persisted drain witness composes exactly the bytes an older build signed");
        var witnessedComposed = CanonicalJson.Canonical((CohortEntryRecord.Fresh(entry) with
        {
            State = CohortEntryStates.Ended,
            Outcome = CohortEntryOutcomes.Complete,
            PreAdoptionOutcome = CohortEntryOutcomes.RunNotComplete
        }).Describe());
        Check(witnessedComposed.Contains("\"preAdoptionOutcome\":\"runNotComplete\"", StringComparison.Ordinal),
            "a record that does carry a drain witness commits it into the signed composition");

        // How the index treats each of those, which is a different question from
        // whether the completion is re-proved. Only a record that CONTRADICTS
        // itself may stop a rebuild; a record that merely predates the witness is
        // dropped, because its journal is signed and can never be repaired.
        var witnessedSummary = SummaryWith(CohortEntryOutcomes.Complete) with
        {
            Record = CohortEntryRecord.Fresh(entry) with
            {
                State = CohortEntryStates.Ended,
                EndedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                ExitCode = CoordinatorExitCodes.Halted,
                Outcome = CohortEntryOutcomes.Complete,
                PreAdoptionOutcome = CohortEntryOutcomes.RunNotComplete
            }
        };
        var (witnessedStanding, _) = CohortCompletionAdoption.Classify(manifest, witnessedSummary);
        Check(witnessedStanding == CohortCompletionAdoption.CompletionStanding.Adopted,
            $"a witnessed, re-provable completion is adopted ({witnessedStanding})");

        var (legacyStanding, legacyStandingWhy) = CohortCompletionAdoption.Classify(manifest, legacySummary);
        Check(legacyStanding == CohortCompletionAdoption.CompletionStanding.DroppedUnwitnessed,
            $"a completion from a build that never took the witness is dropped, not blocked ({legacyStandingWhy})");

        // Unwitnessed AND contradicted is still a stop: age excuses a missing
        // witness, never artifacts that disagree with the record.
        var contradicted = legacySummary with { PreparationTerminalReason = "unexpectedFault" };
        var (contradictedStanding, contradictedWhy) = CohortCompletionAdoption.Classify(manifest, contradicted);
        Check(contradictedStanding == CohortCompletionAdoption.CompletionStanding.Blocked,
            $"an unwitnessed completion whose audit contradicts it still blocks ({contradictedWhy})");

        var timedOutStanding = CohortCompletionAdoption.Classify(manifest, SummaryWith(CohortEntryOutcomes.TimedOut)).Standing;
        Check(timedOutStanding == CohortCompletionAdoption.CompletionStanding.Blocked,
            $"a completion recorded over a tree that was never confirmed stopped blocks ({timedOutStanding})");

        // The other adoption path, and the one a pre-witness root reaches most
        // often: a build that adopted at INDEX time never wrote 'complete' into
        // the journal at all, so its completion lives entirely in the branch that
        // reads a recorded fault beside artifacts saying the target was reached.
        // Classifying only the first path would take the count away from these
        // without naming them anywhere - the number moving quietly that the
        // published list exists to prevent.
        var legacyFaulted = legacySummary with
        {
            Record = legacySummary.Record with { Outcome = CohortEntryOutcomes.PreparationFaulted }
        };
        Check(!legacyFaulted.Record.EndedComplete,
            "the legacy fault-shaped record is not one the journal itself called complete");
        var (faultedStanding, faultedWhy) = CohortCompletionAdoption.Classify(manifest, legacyFaulted);
        Check(faultedStanding == CohortCompletionAdoption.CompletionStanding.DroppedUnwitnessed,
            $"a legacy fault whose artifacts prove the target is dropped, not silently uncounted ({faultedWhy})");

        // Both paths again, this time through the published index rather than
        // through the classifier, because the property that matters is that a
        // REBUILD over a legacy root finishes and states its loss. Publishing is
        // where a wedge would appear: CohortBlockedException is not caught by the
        // runner's index writer, so a throw here ends every future run over the
        // root, and the journal is signed so no operator can repair it.
        var indexKey = Convert.FromHexString(new string('b', 64));
        (string Failure, string IndexPath) PublishOnce(CohortEntrySummary summary)
        {
            try
            {
                Directory.CreateDirectory(manifest.JournalRoot);
                var journal = CohortJournal.LoadOrFresh(manifest, indexKey, keyPreexisted: false);
                CohortIndex.Publish(manifest, journal, indexKey, new[] { summary }, "completed", "none", "none");
                return (string.Empty, manifest.IndexPath);
            }
            catch (Exception ex)
            {
                return (ex.GetType().Name + ": " + ex.Message, string.Empty);
            }
        }

        bool NamesOnlyOrdinalOne(string indexPath, string field)
        {
            var published = StrictJson.ReadObjectFile(indexPath, "cohort index");
            var named = StrictJson.RequireArray(published, field, "cohort index");
            return named.Count == 1 && named[0].GetInt32() == entry.Ordinal;
        }

        var faultedPublish = PublishOnce(legacyFaulted);
        Check(faultedPublish.Failure.Length == 0,
            $"a rebuild over a legacy fault-shaped completion publishes rather than wedging ({faultedPublish.Failure})");
        if (faultedPublish.Failure.Length == 0)
        {
            var publishedIndex = StrictJson.ReadObjectFile(faultedPublish.IndexPath, "cohort index");
            Check(StrictJson.RequireInt(publishedIndex, "completedEntryCount", "cohort index", 0, int.MaxValue) == 0,
                "a completion this build cannot re-prove is not counted complete");
            Check(NamesOnlyOrdinalOne(faultedPublish.IndexPath, "unwitnessedCompleteEntryOrdinals"),
                "the index names the ordinal it stopped counting");
            Check(StrictJson.RequireArray(publishedIndex, "adoptedCompleteEntryOrdinals", "cohort index").Count == 0,
                "the index does not also claim it adopted the ordinal it dropped");
        }

        var completePublish = PublishOnce(legacySummary);
        Check(completePublish.Failure.Length == 0,
            $"a rebuild over a legacy 'complete' record publishes rather than wedging ({completePublish.Failure})");
        if (completePublish.Failure.Length == 0)
        {
            Check(NamesOnlyOrdinalOne(completePublish.IndexPath, "unwitnessedCompleteEntryOrdinals"),
                "both adoption paths state the same loss the same way");
        }

        // The reader's half of the same compatibility rule, proved on bytes. The
        // writer omits the field at 'none', so a file that STATES 'none' is a
        // file that was edited - and a reader that accepted it would recompose
        // bytes without the field, fail its own signature, and tell an operator
        // their journal was tampered with instead of naming the field. Refusing
        // the literal where it is read turns an unrepairable accusation into an
        // answer. The signature is left stale on purpose: the refusal has to come
        // from the field, so this only passes if the field is read first.
        //
        // Its own directory each time, because the case ends by leaving a journal
        // it deliberately edited. A second pass over a reused root would load THAT
        // and end the whole selftest partway through with no failing check
        // printed - a suite that quietly stops being one.
        var literalManifest = manifest with
        {
            JournalRoot = Path.Combine(root, "literal-none-" + Guid.NewGuid().ToString("N")),
            IndexPath = Path.Combine(root, "literal-none-index-" + Guid.NewGuid().ToString("N"), "index.json")
        };
        var literalPrepared = string.Empty;
        var literalText = string.Empty;
        try
        {
            Directory.CreateDirectory(literalManifest.JournalRoot);
            var literalJournal = CohortJournal.LoadOrFresh(literalManifest, indexKey, keyPreexisted: false);
            literalJournal.Commit(
                indexKey,
                CohortEntryRecord.Fresh(entry) with
                {
                    State = CohortEntryStates.Ended,
                    StartedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                    EndedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                    ExitCode = CoordinatorExitCodes.Halted,
                    Outcome = CohortEntryOutcomes.Complete,
                    PreAdoptionOutcome = CohortEntryOutcomes.RunNotComplete,
                    AuditSha256 = digest,
                    SummarySha256 = digest
                },
                "ended",
                "none");
            literalText = File.ReadAllText(literalManifest.JournalPath);
        }
        catch (Exception ex)
        {
            // Reported as a failing check rather than thrown. An escape here
            // would end the selftest with neither a FAIL line nor a count.
            literalPrepared = ex.GetType().Name + ": " + ex.Message;
        }
        Check(literalPrepared.Length == 0,
            $"the literal-'none' case can write the journal it goes on to edit ({literalPrepared})");
        if (literalPrepared.Length == 0)
        {
            // Guarded on the preparation above. The journal path lives INSIDE the
            // root the try block created, so writing it after a failed preparation
            // throws a second, unhandled exception and the selftest ends with no
            // count at all - the failure mode the try block exists to prevent.
            Check(literalText.Contains("\"preAdoptionOutcome\"", StringComparison.Ordinal),
                "a witnessed record really does reach the journal file carrying the field");
            File.WriteAllText(
                literalManifest.JournalPath,
                literalText
                    .Replace(
                        "\"preAdoptionOutcome\": \"" + CohortEntryOutcomes.RunNotComplete + "\"",
                        "\"preAdoptionOutcome\": \"none\"",
                        StringComparison.Ordinal)
                    .Replace(
                        "\"preAdoptionOutcome\":\"" + CohortEntryOutcomes.RunNotComplete + "\"",
                        "\"preAdoptionOutcome\":\"none\"",
                        StringComparison.Ordinal));
            Check(File.ReadAllText(literalManifest.JournalPath).Contains("\"none\"", StringComparison.Ordinal)
                    && !File.ReadAllText(literalManifest.JournalPath).Contains(CohortEntryOutcomes.RunNotComplete, StringComparison.Ordinal),
                "the edited journal really does state the literal this reader must refuse");
            var literalRefusal = string.Empty;
            try
            {
                _ = CohortJournal.LoadOrFresh(literalManifest, indexKey, keyPreexisted: true);
            }
            catch (ContractException ex)
            {
                literalRefusal = ex.Message;
            }
            Check(literalRefusal.Contains("pre-adoption", StringComparison.OrdinalIgnoreCase),
                $"a journal stating the literal 'none' is refused at the field, not as a tampered file ({literalRefusal})");
        }

        if (failures == 0 && checks != declaredChecks)
        {
            log.WriteLine($"  FAIL  the selftest ran {checks} checks, not the {declaredChecks} it declares");
            failures++;
        }

        if (failures == 0)
        {
            log.WriteLine();
            log.WriteLine($"All {checks} completion adoption checks passed.");
        }
        return failures == 0 ? 0 : 1;
    }
}

internal static class CohortIndex
{
    /// <remarks>
    /// v4 is v3 plus 'unwitnessedCompleteEntryOrdinals'. The list was added
    /// without a bump, so a v3 index cannot be told apart from one written
    /// before the list existed - and something reading two indexes has to know
    /// whether a missing list means "none" or "this build did not say". v4 is
    /// the version at which the absence of that list is a fact rather than an
    /// era.
    /// </remarks>
    internal const string ContractVersionValue = "devpilot.shadow-cohort.index.v4";
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
        long verifierProcesses = 0;
        long seconds = 0;
        long writes = 0;
        var completed = 0;
        var pending = 0;
        var adoptedOrdinals = new ListNode();
        var unwitnessedOrdinals = new ListNode();
        foreach (var summary in summaries)
        {
            entries.Add(summary.Describe());
            models += summary.ModelStartCount;
            verifiers += summary.VerifierAssignmentCount;
            verifierProcesses += summary.VerifierProcessStartCount;
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
                    var (standing, reason) = CohortCompletionAdoption.Classify(manifest, summary);
                    if (standing == CohortCompletionAdoption.CompletionStanding.Blocked)
                    {
                        throw new CohortBlockedException(
                            $"Entry {summary.Entry.Ordinal.ToString(CultureInfo.InvariantCulture)} is recorded complete after exiting " +
                            $"{summary.Record.ExitCode.ToString(CultureInfo.InvariantCulture)}, and this build cannot reproduce the proof it was " +
                            $"adopted on: {reason}. An index that published a completion it could not re-derive would be a record standing on " +
                            "artifacts that no longer say what it says.");
                    }
                    if (standing == CohortCompletionAdoption.CompletionStanding.DroppedUnwitnessed)
                    {
                        // Not counted, not blocked, and not silent. The journal is
                        // signed, so the witness it never took cannot be added;
                        // ending every future run over this root would be a worse
                        // answer than publishing it as the not-complete entry it
                        // can prove. The ordinal is published so the loss is a
                        // stated one rather than a number that quietly moved.
                        unwitnessedOrdinals.Add(Node.Number(summary.Entry.Ordinal));
                    }
                    else
                    {
                        adoptedOrdinals.Add(Node.Number(summary.Entry.Ordinal));
                        completed++;
                    }
                }
                else
                {
                    completed++;
                }
            }
            else
            {
                // A root written by an earlier build, whose journal recorded the
                // exit code and called it a fault. The artifacts say otherwise and
                // the artifacts are signed, so the count says what the artifacts
                // say. The per-entry summary is left exactly as it was committed:
                // it is digest-bound to the journal, and an index that rewrote it
                // would be an index that could no longer be checked against the
                // record it was derived from.
                //
                // Classified rather than merely evaluated, and classified the same
                // way the branch above classifies: a pre-witness journal reaches
                // completion through THIS path far more often than through the
                // other one, because a build that adopted at index time never wrote
                // 'complete' into the journal at all. Deciding it with the
                // witness-requiring answer alone would drop such an entry out of
                // all three published numbers without saying so - the exact count
                // that quietly moved the other branch names its losses to avoid.
                // Nothing here throws: this record does not claim to be complete,
                // so failing to adopt it is an absence of proof rather than a
                // record contradicting itself.
                var (standing, _) = CohortCompletionAdoption.Classify(manifest, summary);
                if (standing == CohortCompletionAdoption.CompletionStanding.Adopted)
                {
                    completed++;
                    adoptedOrdinals.Add(Node.Number(summary.Entry.Ordinal));
                }
                else if (standing == CohortCompletionAdoption.CompletionStanding.DroppedUnwitnessed)
                {
                    unwitnessedOrdinals.Add(Node.Number(summary.Entry.Ordinal));
                }
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
            // Entries a previous build published as complete whose proof this
            // build cannot re-run, because the journal predates the witness that
            // proof rests on. Both adoption paths feed this list - the entry the
            // journal called complete and the entry the journal called a fault
            // whose artifacts said otherwise - so a legacy root loses the same
            // way whichever shape it was written in. They are not counted as
            // complete and they do not stop the index; naming them keeps the
            // difference between the two counts readable instead of leaving a
            // number that quietly moved.
            .Set("unwitnessedCompleteEntryOrdinals", unwitnessedOrdinals)
            .Set("pendingEntryCount", pending)
            .Set("budgets", manifest.Budgets.Describe())
            .Set("consumed", new MapNode()
                .Set("modelStarts", models)
                .Set("verifierAssignments", verifiers)
                // Grouped launches, published beside the assignments they served
                // so a reader can see the difference rather than infer it. No
                // ceiling is checked against this.
                .Set("verifierProcessStarts", verifierProcesses)
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
