using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Thrown when a cohort entry's previous launch was never accounted for, so this
/// run declines to guess what it left behind.
/// </summary>
internal sealed class CohortUnresolvedLaunchException(string message) : Exception(message);

/// <summary>The ways one declared entry can be at rest in the journal.</summary>
internal static class CohortEntryStates
{
    /// <summary>Declared, never started. The state every entry begins and a budget stop leaves.</summary>
    internal const string Pending = "pending";

    /// <summary>An intent was committed. Whether a process exists is unknown from here alone.</summary>
    internal const string LaunchIntended = "launchIntended";

    /// <summary>A child was started and its exact identity is recorded.</summary>
    internal const string Running = "running";

    /// <summary>The child was observed to end and its outcome is accounted for. Never launched again.</summary>
    internal const string Ended = "ended";

    /// <summary>The whole cohort refuses to touch this entry. Never launched.</summary>
    internal const string Blocked = "blocked";

    internal static bool IsKnown(string state) =>
        state is Pending or LaunchIntended or Running or Ended or Blocked;
}

/// <summary>The ways an entry that ended can have ended.</summary>
/// <remarks>
/// Passthrough words for what the child reported, not judgements formed here.
/// 'complete' is the one the typed coordinator signals with a zero exit; the rest
/// separate the failures that mean different things, exactly as the single-run
/// exit codes do, so an operator can tell a preparation that refused its request
/// from one whose supervised run ended other than complete.
/// </remarks>
internal static class CohortEntryOutcomes
{
    internal const string Complete = "complete";

    /// <summary>The preparation ran and its supervised run ended other than complete.</summary>
    internal const string RunNotComplete = "runNotComplete";

    /// <summary>The preparation refused, faulted, or exited for a reason of its own.</summary>
    internal const string PreparationFaulted = "preparationFaulted";

    /// <summary>The entry exceeded its declared wall-clock budget and its tree was killed.</summary>
    internal const string TimedOut = "timedOut";

    /// <summary>The child could not be proven stopped, so nothing may run against this root again.</summary>
    internal const string Abandoned = "abandoned";

    /// <summary>
    /// The entry ran and the evidence it published was refused by the cohort.
    /// </summary>
    /// <remarks>
    /// This is an ENDING, not a fault the runner can leave open. An entry whose
    /// audit reports a write, or which this build cannot read as an audit of its
    /// own, has already had its preparation run against its output root; leaving
    /// it unended would let a later resume start a second one. So the ending is
    /// committed with this outcome and the cohort then stops, and every later run
    /// over this journal stops on it again rather than walking past it.
    /// </remarks>
    internal const string EvidenceRefused = "evidenceRefused";

    internal static bool IsKnown(string outcome) =>
        outcome is Complete or RunNotComplete or PreparationFaulted or TimedOut or Abandoned or EvidenceRefused;
}

/// <summary>The durable record of one entry inside a cohort journal.</summary>
internal sealed record CohortEntryRecord
{
    internal required int Ordinal { get; init; }

    internal required string EntryId { get; init; }

    internal required string State { get; init; }

    /// <summary>How many times a child has been started for this entry. Never more than one after it ends.</summary>
    internal required int Attempt { get; init; }

    /// <summary>The digest of the exact launch specification the intent was committed for.</summary>
    internal required string IntentSha256 { get; init; }

    internal required int ChildProcessId { get; init; }

    internal required string ChildStartedAtUtc { get; init; }

    internal required string StartedAtUtc { get; init; }

    internal required string EndedAtUtc { get; init; }

    internal required int ExitCode { get; init; }

    internal required string Outcome { get; init; }

    internal required int ElapsedSeconds { get; init; }

    internal required int ModelStartCount { get; init; }

    internal required int VerifierAssignmentCount { get; init; }

    internal required int SlotLaunchCount { get; init; }

    internal required int ProviderWriteCount { get; init; }

    internal required string AuditSha256 { get; init; }

    internal required string SummarySha256 { get; init; }

    internal static CohortEntryRecord Fresh(CohortEntry entry) => new()
    {
        Ordinal = entry.Ordinal,
        EntryId = entry.EntryId,
        State = CohortEntryStates.Pending,
        Attempt = 0,
        IntentSha256 = "none",
        ChildProcessId = 0,
        ChildStartedAtUtc = "none",
        StartedAtUtc = "none",
        EndedAtUtc = "none",
        ExitCode = -1,
        Outcome = "none",
        ElapsedSeconds = 0,
        ModelStartCount = 0,
        VerifierAssignmentCount = 0,
        SlotLaunchCount = 0,
        ProviderWriteCount = 0,
        AuditSha256 = "none",
        SummarySha256 = "none"
    };

    internal MapNode Describe() => new MapNode()
        .Set("ordinal", Ordinal)
        .Set("entryId", EntryId)
        .Set("state", State)
        .Set("attempt", Attempt)
        .Set("intentSha256", IntentSha256)
        .Set("childProcessId", ChildProcessId)
        .Set("childStartedAtUtc", ChildStartedAtUtc)
        .Set("startedAtUtc", StartedAtUtc)
        .Set("endedAtUtc", EndedAtUtc)
        .Set("exitCode", ExitCode)
        .Set("outcome", Outcome)
        .Set("elapsedSeconds", ElapsedSeconds)
        .Set("modelStartCount", ModelStartCount)
        .Set("verifierAssignmentCount", VerifierAssignmentCount)
        .Set("slotLaunchCount", SlotLaunchCount)
        .Set("providerWriteCount", ProviderWriteCount)
        .Set("auditSha256", AuditSha256)
        .Set("summarySha256", SummarySha256);

    internal static CohortEntryRecord Read(JsonElement node, string label)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} holds a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "ordinal",
            "entryId",
            "state",
            "attempt",
            "intentSha256",
            "childProcessId",
            "childStartedAtUtc",
            "startedAtUtc",
            "endedAtUtc",
            "exitCode",
            "outcome",
            "elapsedSeconds",
            "modelStartCount",
            "verifierAssignmentCount",
            "slotLaunchCount",
            "providerWriteCount",
            "auditSha256",
            "summarySha256");

        var state = StrictJson.RequireString(node, "state", label);
        if (!CohortEntryStates.IsKnown(state))
        {
            throw new ContractException($"The {label} records state '{state}', which is not a state this build writes.");
        }
        var outcome = StrictJson.RequireString(node, "outcome", label);
        if (!string.Equals(outcome, "none", StringComparison.Ordinal) && !CohortEntryOutcomes.IsKnown(outcome))
        {
            throw new ContractException($"The {label} records outcome '{outcome}', which is not an outcome this build writes.");
        }
        // An ended entry without an outcome, or an outcome on an entry that never
        // ended, would each let the accounting read as something the record does
        // not say. Refused rather than repaired.
        if (string.Equals(state, CohortEntryStates.Ended, StringComparison.Ordinal)
            && string.Equals(outcome, "none", StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} says the entry ended and records no outcome; an ending is the outcome it recorded.");
        }

        return new CohortEntryRecord
        {
            Ordinal = StrictJson.RequireInt(node, "ordinal", label, 1, 64),
            EntryId = StrictJson.RequireString(node, "entryId", label),
            State = state,
            Attempt = StrictJson.RequireInt(node, "attempt", label, 0, 64),
            IntentSha256 = StrictJson.RequireString(node, "intentSha256", label),
            ChildProcessId = StrictJson.RequireInt(node, "childProcessId", label, 0, int.MaxValue),
            ChildStartedAtUtc = StrictJson.RequireString(node, "childStartedAtUtc", label),
            StartedAtUtc = StrictJson.RequireString(node, "startedAtUtc", label),
            EndedAtUtc = StrictJson.RequireString(node, "endedAtUtc", label),
            // A process exit code is whatever the operating system reports, and on
            // Windows an unhandled managed exception reports 0xE0434352 as a
            // negative number. Bounding this field to the sentinel's range would
            // mean the writer could commit an ending the reader then refuses,
            // which would wedge a signed journal no operator can edit.
            ExitCode = StrictJson.RequireInt(node, "exitCode", label, int.MinValue, int.MaxValue),
            Outcome = outcome,
            ElapsedSeconds = StrictJson.RequireInt(node, "elapsedSeconds", label, 0, int.MaxValue),
            ModelStartCount = StrictJson.RequireInt(node, "modelStartCount", label, 0, int.MaxValue),
            VerifierAssignmentCount = StrictJson.RequireInt(node, "verifierAssignmentCount", label, 0, int.MaxValue),
            SlotLaunchCount = StrictJson.RequireInt(node, "slotLaunchCount", label, 0, int.MaxValue),
            ProviderWriteCount = StrictJson.RequireInt(node, "providerWriteCount", label, 0, int.MaxValue),
            AuditSha256 = StrictJson.RequireString(node, "auditSha256", label),
            SummarySha256 = StrictJson.RequireString(node, "summarySha256", label)
        };
    }

    /// <summary>True when this entry has ended and may never be started again.</summary>
    internal bool HasEnded => string.Equals(State, CohortEntryStates.Ended, StringComparison.Ordinal);

    /// <summary>True when this entry ended the one way that counts as done.</summary>
    internal bool EndedComplete => HasEnded && string.Equals(Outcome, CohortEntryOutcomes.Complete, StringComparison.Ordinal);

    /// <summary>True when this entry's own published evidence was refused.</summary>
    internal bool EndedRefused => HasEnded && string.Equals(Outcome, CohortEntryOutcomes.EvidenceRefused, StringComparison.Ordinal);

    /// <summary>True when a launch was committed for this entry and no ending was ever recorded.</summary>
    internal bool HasOpenLaunch =>
        string.Equals(State, CohortEntryStates.LaunchIntended, StringComparison.Ordinal)
        || string.Equals(State, CohortEntryStates.Running, StringComparison.Ordinal);
}

/// <summary>
/// The durable, signed, atomically replaced account of how far one cohort got.
/// </summary>
/// <remarks>
/// It is the single-run state record's argument one level up. The sequence is
/// monotonic, so a journal that went backwards is a refusal rather than a rewind.
/// The record is signed, so a truncated or edited journal is refused rather than
/// believed. The whole file is replaced through a sibling temporary, so a runner
/// killed mid-write leaves either the old journal or the new one and never half
/// of either. And it is bound to the manifest's digest, so a cohort that gained,
/// lost or reordered an entry cannot resume onto a journal describing the old
/// one.
///
/// What it adds over the single-run record is the one fact a per-entry state file
/// cannot hold: the INTENT to start an entry, committed before that entry's
/// coordinator exists. A runner killed between deciding to start entry three and
/// entry three writing anything at all leaves no per-entry evidence whatsoever;
/// without the intent here, a resume could not tell that case from an entry that
/// was never reached, and would start a second preparation of a subject whose
/// first one may still be running.
///
/// The signature is not an adversary defence and is not claimed as one: the key
/// sits beside the journal under the same ownership. What it catches is the fault
/// this design actually meets - a partially written, truncated or hand-edited
/// journal being resumed from as though it were evidence.
/// </remarks>
internal sealed class CohortJournal
{
    internal const string ContractVersionValue = "devpilot.shadow-cohort.journal.v1";
    internal const string KindValue = "shadow-cohort-journal";

    private const string Label = "shadow cohort journal";

    private readonly CohortManifest _manifest;
    private readonly Dictionary<string, CohortEntryRecord> _entries = new(StringComparer.Ordinal);
    private readonly List<MapNode> _events = [];

    private CohortJournal(CohortManifest manifest, string bindingSha256)
    {
        _manifest = manifest;
        BindingSha256 = bindingSha256;
    }

    internal int Sequence { get; private set; }

    /// <summary>The digest of the cohort binding this journal was opened under.</summary>
    internal string BindingSha256 { get; }

    internal IReadOnlyList<MapNode> Events => _events;

    /// <summary>The record for a declared entry, which always exists once the journal is open.</summary>
    internal CohortEntryRecord RecordFor(string entryId) =>
        _entries.TryGetValue(entryId, out var record)
            ? record
            : throw new ContractException($"The {Label} holds no record for entry '{entryId}'.");

    internal static string BindingDigest(CohortManifest manifest) =>
        CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(manifest.Describe()));

    /// <summary>
    /// The signing key for this journal root, minted once and reused.
    /// </summary>
    /// <remarks>
    /// A minted key is deliberately NOT written here, for the same reason the
    /// single-run key is not: the key's presence is the evidence that a journal
    /// once existed, so writing it before the journal it signs would make an
    /// ordinary first-attempt crash indistinguishable from a destroyed journal
    /// and would wedge a root that has published nothing at all.
    /// </remarks>
    internal static byte[] LoadOrMintKey(CohortManifest manifest, out bool preexisted)
    {
        Directory.CreateDirectory(manifest.JournalRoot);
        if (File.Exists(manifest.JournalKeyPath))
        {
            preexisted = true;
            return ReadKey(manifest);
        }
        preexisted = false;
        return RandomNumberGenerator.GetBytes(32);
    }

    /// <summary>
    /// True when this root records a launch this run cannot account for.
    /// </summary>
    /// <remarks>
    /// An intent is written before every attempt and never removed, so a root
    /// holding one has started something. This is what separates "a first run
    /// died before its journal reached the disk" from "somebody removed the
    /// journal", which are otherwise the same two files on disk.
    /// </remarks>
    private static bool HasRecordedIntent(CohortManifest manifest) =>
        Directory.Exists(manifest.IntentRoot)
        && Directory.EnumerateFiles(manifest.IntentRoot, "*.intent.json", SearchOption.TopDirectoryOnly).Any();

    private static byte[] ReadKey(CohortManifest manifest)
    {
        var text = File.ReadAllText(manifest.JournalKeyPath, StrictJson.StrictUtf8).Trim();
        if (text.Length != 64 || !StrictJson.IsLowerHex(text))
        {
            throw new ContractException($"The cohort journal key at '{manifest.JournalKeyPath}' is not 64 lower-case hexadecimal characters.");
        }
        return Convert.FromHexString(text);
    }

    /// <summary>
    /// Loads the journal for this manifest, or opens a fresh one when there is
    /// nothing to resume. A journal that exists but belongs to another cohort is
    /// a refusal, never a fresh start.
    /// </summary>
    internal static CohortJournal LoadOrFresh(CohortManifest manifest, byte[] key, bool keyPreexisted)
    {
        var binding = BindingDigest(manifest);
        if (!File.Exists(manifest.JournalPath))
        {
            // A key without a journal usually says a journal that existed has since
            // been removed, and the entries it accounted for cannot be re-derived
            // from anywhere: the per-entry roots would look startable again. There
            // is one honest exception, and it is exactly the case a first run can
            // produce by itself - a runner killed after the key was written and
            // before the first journal reached the disk. That run committed
            // nothing, so it also wrote no launch intent, and a root holding no
            // intent has demonstrably started nothing. The refusal happens here,
            // before anything is mutated.
            if (keyPreexisted && HasRecordedIntent(manifest))
            {
                throw new ContractException(
                    $"The cohort journal root '{manifest.JournalRoot}' carries a signing key and no journal at '{manifest.JournalPath}', " +
                    "and the intent root records launches this run cannot account for. " +
                    "The record this run would have resumed from has been removed, so the entries it accounted for cannot be accounted for now. " +
                    "This journal root is not resumable and is not started over; use a fresh one.");
            }
            return Fresh(manifest, binding);
        }

        var root = StrictJson.ReadObjectFile(manifest.JournalPath, Label);
        StrictJson.RequireNoUnknownFields(
            root,
            Label,
            "contractVersion",
            "kind",
            "cohortId",
            "manifestSha256",
            "bindingSha256",
            "sequence",
            "entries",
            "events",
            "signature");

        StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, Label);
        StrictJson.RequireLiteral(root, "kind", KindValue, Label);

        var signature = StrictJson.RequireObject(root, "signature", Label);
        StrictJson.RequireNoUnknownFields(signature, Label + " signature", "algorithm", "value");
        StrictJson.RequireLiteral(signature, "algorithm", "HMACSHA256", Label + " signature");
        var recordedSignature = StrictJson.RequireHex(signature, "value", Label + " signature", 64);

        var cohortId = StrictJson.RequireString(root, "cohortId", Label);
        var manifestSha256 = StrictJson.RequireHex(root, "manifestSha256", Label, 64);
        var bindingSha256 = StrictJson.RequireHex(root, "bindingSha256", Label, 64);
        var sequence = StrictJson.RequireInt(root, "sequence", Label, 0, int.MaxValue);

        var journal = new CohortJournal(manifest, bindingSha256) { Sequence = sequence };

        foreach (var entryNode in StrictJson.RequireArray(root, "entries", Label))
        {
            var record = CohortEntryRecord.Read(entryNode, Label + " entry");
            if (journal._entries.ContainsKey(record.EntryId))
            {
                throw new ContractException($"The {Label} records entry '{record.EntryId}' twice; one handle has one account.");
            }
            journal._entries[record.EntryId] = record;
        }

        var previousSequence = 0;
        foreach (var eventNode in StrictJson.RequireArray(root, "events", Label))
        {
            if (eventNode.ValueKind != JsonValueKind.Object)
            {
                throw new ContractException($"The {Label} events hold a {StrictJson.Describe(eventNode.ValueKind)}, not an object.");
            }
            StrictJson.RequireNoUnknownFields(eventNode, Label + " event", "sequence", "atUtc", "entryId", "kind", "detail");
            var eventSequence = StrictJson.RequireInt(eventNode, "sequence", Label + " event", 1, int.MaxValue);
            if (eventSequence <= previousSequence)
            {
                throw new ContractException(
                    $"The {Label} event sequence went from {previousSequence.ToString(CultureInfo.InvariantCulture)} to " +
                    $"{eventSequence.ToString(CultureInfo.InvariantCulture)}; a durable sequence only ever increases.");
            }
            previousSequence = eventSequence;
            journal._events.Add((MapNode)Node.FromJson(eventNode, Label + " event"));
        }
        if (previousSequence != sequence)
        {
            throw new ContractException(
                $"The {Label} says sequence {sequence.ToString(CultureInfo.InvariantCulture)} but its last event is " +
                $"{previousSequence.ToString(CultureInfo.InvariantCulture)}.");
        }

        // Every declared entry has an account, and every account belongs to a
        // declared entry. This is settled BEFORE the signature is checked,
        // because composing the journal for signing indexes the account of every
        // declared entry: a manifest that grew an entry would otherwise fault
        // inside the signature check instead of being told what is wrong.
        foreach (var entry in manifest.Entries)
        {
            if (!journal._entries.TryGetValue(entry.EntryId, out var record))
            {
                throw new ContractException($"The {Label} holds no account for declared entry '{entry.EntryId}'.");
            }
            if (record.Ordinal != entry.Ordinal)
            {
                throw new ContractException($"The {Label} records entry '{entry.EntryId}' at a different ordinal than the manifest declares.");
            }
        }
        foreach (var recorded in journal._entries.Keys)
        {
            _ = manifest.RequireEntry(recorded);
        }

        var expected = CanonicalJson.HmacHex(key, CanonicalJson.Canonical(journal.Compose()));
        if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expected), Convert.FromHexString(recordedSignature)))
        {
            throw new ContractException($"The {Label} at '{manifest.JournalPath}' does not match its own signature; it was truncated or edited after it was written.");
        }

        if (!string.Equals(cohortId, manifest.CohortId, StringComparison.Ordinal))
        {
            throw new ContractException($"The {Label} belongs to cohort '{cohortId}', and this manifest declares '{manifest.CohortId}'.");
        }
        if (!string.Equals(manifestSha256, manifest.ManifestSha256, StringComparison.Ordinal))
        {
            throw new ContractException($"The {Label} was written for a different manifest; resuming a cohort under changed inputs is refused.");
        }
        if (!string.Equals(bindingSha256, binding, StringComparison.Ordinal))
        {
            throw new ContractException($"The {Label} was written for a different cohort binding; resuming onto another set of entries, budgets or pins is refused.");
        }
        return journal;
    }

    private static CohortJournal Fresh(CohortManifest manifest, string binding)
    {
        var journal = new CohortJournal(manifest, binding);
        foreach (var entry in manifest.Entries)
        {
            journal._entries[entry.EntryId] = CohortEntryRecord.Fresh(entry);
        }
        return journal;
    }

    /// <summary>The most attempts one entry's account can carry, matching what the reader admits.</summary>
    /// <remarks>
    /// A resume is not a retry, so the only thing that raises this is an operator
    /// re-running a cohort whose entry keeps being interrupted. Sixty-four of
    /// those is not a transient condition; it is a root that needs a person. The
    /// cap is enforced where the record is written so the writer can never commit
    /// an account its own reader would refuse, which would wedge a signed journal
    /// nobody can edit.
    /// </remarks>
    internal const int MaximumAttempts = 64;

    /// <summary>
    /// Replaces one entry's account and commits the journal before returning, so
    /// the caller may be killed immediately afterwards and a resume still sees
    /// what was committed.
    /// </summary>
    internal void Commit(byte[] key, CohortEntryRecord record, string kind, string detail)
    {
        if (!_entries.TryGetValue(record.EntryId, out var previous))
        {
            throw new ContractException($"The {Label} holds no record for entry '{record.EntryId}'.");
        }
        RequireWritable(record);
        // An entry that has ended is closed. Every path that could reopen one -
        // a retry, a replacement, a second pass over the manifest - is refused
        // here rather than in each of the callers that might one day want it.
        if (previous.HasEnded)
        {
            throw new ContractException(
                $"Entry '{record.EntryId}' already ended '{previous.Outcome}' in the {Label}. " +
                "A cohort never re-attempts or replaces an entry that ended; the ending is the account.");
        }
        var previousSequence = Sequence;
        Sequence++;
        _entries[record.EntryId] = record;
        _events.Add(new MapNode()
            .Set("sequence", Sequence)
            .Set("atUtc", DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture))
            .Set("entryId", record.EntryId)
            .Set("kind", kind)
            .Set("detail", detail));
        try
        {
            Save(key);
        }
        catch
        {
            // The journal never reached the disk, so this object stops claiming
            // it did. Without the rollback the commit survives in memory and the
            // index written on the way out would describe an account the durable
            // record does not contain.
            _events.RemoveAt(_events.Count - 1);
            _entries[record.EntryId] = previous;
            Sequence = previousSequence;
            throw;
        }
    }

    /// <summary>
    /// Refuses a record this journal's own reader would not admit.
    /// </summary>
    /// <remarks>
    /// The journal is signed, so a record that saves and then fails to load
    /// cannot be repaired by hand: the only way out would be a fresh root, which
    /// reopens every ended entry as pending and re-launches subjects that already
    /// ran. Every bound the reader applies is therefore applied here first, where
    /// crossing it is still an ordinary refusal.
    /// </remarks>
    private void RequireWritable(CohortEntryRecord record)
    {
        if (record.Attempt > MaximumAttempts)
        {
            throw new ContractException(
                $"Entry '{record.EntryId}' has been attempted {record.Attempt.ToString(CultureInfo.InvariantCulture)} times in the {Label}, " +
                $"and an account carries at most {MaximumAttempts.ToString(CultureInfo.InvariantCulture)}. An entry interrupted this many " +
                "times is not a transient condition; settle it by hand rather than resuming again.");
        }
        if (record.ChildStartedAtUtc.Length == 0)
        {
            throw new ContractException(
                $"Entry '{record.EntryId}' would be committed with an empty child start time. A record the reader refuses cannot be " +
                "written into a signed journal; a start time that could not be read is recorded as 'none' and refused on resume instead.");
        }
    }

    internal void Save(byte[] key)
    {
        var effective = PersistKey(key);
        var signature = CanonicalJson.HmacHex(effective, CanonicalJson.Canonical(Compose()));
        // Composed a second time rather than reused: the node is mutable, and
        // signing a map and then adding a field to that same map would leave the
        // signature covering bytes the file no longer holds.
        var signed = Compose();
        signed.Set("signature", new MapNode().Set("algorithm", "HMACSHA256").Set("value", signature));
        CanonicalJson.WriteFileAtomic(_manifest.JournalPath, CanonicalJson.Readable(signed));
    }

    /// <summary>
    /// Writes the minted key if this root has none, and adopts an existing one if
    /// something else won the race. Minting a second key would make every record
    /// written under the first unverifiable.
    /// </summary>
    private byte[] PersistKey(byte[] key)
    {
        Directory.CreateDirectory(_manifest.JournalRoot);
        if (File.Exists(_manifest.JournalKeyPath))
        {
            return ReadKey(_manifest);
        }
        try
        {
            using var stream = new FileStream(_manifest.JournalKeyPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var bytes = StrictJson.StrictUtf8.GetBytes(Convert.ToHexString(key).ToLowerInvariant());
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(flushToDisk: true);
            return key;
        }
        catch (IOException) when (File.Exists(_manifest.JournalKeyPath))
        {
            return ReadKey(_manifest);
        }
    }

    internal MapNode Compose()
    {
        var entries = new ListNode();
        // Ordered by the manifest's own order rather than by dictionary order, so
        // two journals holding the same facts canonicalize to the same bytes.
        foreach (var declared in _manifest.Entries)
        {
            entries.Add(_entries[declared.EntryId].Describe());
        }
        var events = new ListNode();
        foreach (var recorded in _events)
        {
            events.Add(recorded);
        }
        return new MapNode()
            .Set("contractVersion", ContractVersionValue)
            .Set("kind", KindValue)
            .Set("cohortId", _manifest.CohortId)
            .Set("manifestSha256", _manifest.ManifestSha256)
            .Set("bindingSha256", BindingSha256)
            .Set("sequence", Sequence)
            .Set("entries", entries)
            .Set("events", events);
    }

    /// <summary>
    /// Refuses to proceed past an entry whose committed launch was never
    /// accounted for and whose child cannot be proven gone.
    /// </summary>
    /// <remarks>
    /// The two cases are deliberately different. A recorded child that is STILL
    /// ALIVE means a previous runner was killed and its entry's coordinator is
    /// still writing that entry's output root; starting anything beside it would
    /// put two writers in one root. A recorded child that is provably gone is the
    /// ordinary crash, and the entry may be resumed - the per-entry coordinator's
    /// own signed state, lease and launch ledger are what make that resume
    /// idempotent, and nothing here duplicates that reasoning.
    ///
    /// The third case is the one that has no evidence at all: an intent committed
    /// and no child identity recorded. A runner killed inside process creation
    /// leaves exactly that, and it is not knowable from here whether a process
    /// exists. It is reported as unresolved rather than guessed at, because
    /// guessing 'no child' is what would start a second preparation of a live
    /// subject.
    /// </remarks>
    internal void RequireResumable(CohortEntryRecord record)
    {
        if (!record.HasOpenLaunch)
        {
            return;
        }
        if (string.Equals(record.State, CohortEntryStates.LaunchIntended, StringComparison.Ordinal))
        {
            throw new CohortUnresolvedLaunchException(
                $"Entry '{record.EntryId}' has a committed launch intent and no recorded child. A runner killed between committing the " +
                "intent and recording what it started leaves exactly this, and whether a preparation is running against that entry's " +
                "output root cannot be decided from here. Confirm nothing is running for that entry, then clear the intent by hand.");
        }
        // A running record whose child identity is not usable is the same question
        // as the one above wearing a different state name. Liveness here is decided
        // from a process id AND an exact start time, because a process id on its own
        // is recycled; a record missing either cannot answer "is it still running?",
        // and answering "no" is precisely what would start a second preparation
        // against a live output root.
        if (record.ChildProcessId <= 0 || record.ChildStartedAtUtc.Length == 0
            || string.Equals(record.ChildStartedAtUtc, "none", StringComparison.Ordinal))
        {
            throw new CohortUnresolvedLaunchException(
                $"Entry '{record.EntryId}' records a started child whose identity is incomplete " +
                $"(process {record.ChildProcessId.ToString(CultureInfo.InvariantCulture)}, started '{record.ChildStartedAtUtc}'). " +
                "Whether that preparation is still running cannot be decided from this record, and this run does not guess. " +
                "Confirm nothing is running for that entry, then clear the record by hand.");
        }
        if (IsRecordedChildAlive(record))
        {
            throw new CohortUnresolvedLaunchException(
                $"Entry '{record.EntryId}' records a live child (process {record.ChildProcessId.ToString(CultureInfo.InvariantCulture)}, " +
                $"started {record.ChildStartedAtUtc}). A runner that was killed leaves its entry's preparation running; this run does not " +
                "start anything beside it. Wait for that preparation to exit, or end it, and run again.");
        }
    }

    /// <summary>
    /// True when the exact recorded child is still running. A matching identifier
    /// whose start time differs is a recycled identifier and is deliberately not
    /// the child.
    /// </summary>
    internal static bool IsRecordedChildAlive(CohortEntryRecord record)
    {
        if (record.ChildProcessId <= 0 || record.ChildStartedAtUtc.Length == 0
            || string.Equals(record.ChildStartedAtUtc, "none", StringComparison.Ordinal))
        {
            return false;
        }
        Process candidate;
        try
        {
            candidate = Process.GetProcessById(record.ChildProcessId);
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        using (candidate)
        {
            return ChildJournal.IsSameProcess(candidate, record.ChildStartedAtUtc);
        }
    }
}
