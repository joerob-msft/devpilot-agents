using System.Globalization;
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
internal sealed class CohortBlockedException(string message) : Exception(message);

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

    internal required int ModelStartCount { get; init; }

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
        SlotLaunchCount = 0,
        SupervisedSlotCount = 0,
        VerifierAssignmentCount = 0,
        ProviderWriteCount = 0,
        WriteToolInvocationCount = 0,
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
    private const string AuditContractVersion = "devpilot.shadow-run-coordinator.audit.v1";
    private const string AuditKind = "shadow-run-coordinator-audit";

    /// <summary>The audit an entry's output root publishes.</summary>
    internal static string AuditPathFor(CohortEntry entry) =>
        Path.Combine(entry.OutputRoot, "coordinator", "audit.json");

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
        try
        {
            audit = StrictJson.ReadObjectFile(path, label);
            StrictJson.RequireLiteral(audit, "contractVersion", AuditContractVersion, label);
            StrictJson.RequireLiteral(audit, "kind", AuditKind, label);
            // The one binding that says this audit belongs to the preparation this
            // entry declared, rather than being an audit left standing in that root
            // by something else. The correlation is the request's own, read out of
            // the request the manifest sealed, so an audit adopted from another
            // preparation is refused instead of counted.
            StrictJson.RequireLiteral(audit, "correlationId", expectedCorrelationId, label);
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
            AuditSha256 = CanonicalJson.Sha256HexOfFile(path),
            StateSha256 = ReadText(audit, "stateSha256"),
            ModelStartCount = RequireRepresentable(ReadCount(audit, "modelInvocationCount") + SlotModelStarts(audit), "modelInvocationCount", label),
            SlotLaunchCount = RequireRepresentable(ReadCount(audit, "slotLaunchCount"), "slotLaunchCount", label),
            SupervisedSlotCount = RequireRepresentable(ReadCount(audit, "supervisedSlotCount"), "supervisedSlotCount", label),
            VerifierAssignmentCount = verifierAssignments,
            ProviderWriteCount = providerWrites,
            WriteToolInvocationCount = writeInvocations,
            WallClockSeconds = wallClockSeconds
        };
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
                "remaining entry is abandoned rather than run beside a preparation that wrote.");
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
    /// The model starts each supervised slot reported, added up. The audit copies
    /// these across from the reviewed terminal artifact by position; so does this.
    /// </summary>
    private static long SlotModelStarts(JsonElement audit)
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
            total += ReadCount(slot, "slotModelInvocationCount");
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
internal static class CohortIndex
{
    internal const string ContractVersionValue = "devpilot.shadow-cohort.index.v1";
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

    internal const string ReasonBlocked = "blocked";

    internal const string ReasonUnresolvedLaunch = "unresolvedLaunch";

    internal const string ReasonContractRefusal = "contractRefusal";

    internal const string ReasonUnexpectedFault = "unexpectedFault";

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
        foreach (var summary in summaries)
        {
            entries.Add(summary.Describe());
            models += summary.ModelStartCount;
            verifiers += summary.VerifierAssignmentCount;
            seconds += summary.WallClockSeconds;
            writes += summary.ProviderWriteCount;
            if (summary.Record.EndedComplete)
            {
                completed++;
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
            .Set("pendingEntryCount", pending)
            .Set("budgets", manifest.Budgets.Describe())
            .Set("consumed", new MapNode()
                .Set("modelStarts", models)
                .Set("verifierAssignments", verifiers)
                .Set("wallClockSeconds", seconds)
                .Set("providerWrites", writes))
            .Set("entries", entries)
            .Set("journalSequence", journal.Sequence)
            .Set("journalSha256", File.Exists(manifest.JournalPath) ? CanonicalJson.Sha256HexOfFile(manifest.JournalPath) : "none")
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
}
