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

    /// <summary>A legacy entry timeout recorded before custody became uniformly fail-closed.</summary>
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

    /// <summary>
    /// The outcomes a runner reaches ONLY after it has positively witnessed the
    /// supervised coordinator's output streams reach EOF and its process tree stop
    /// under an ending whose contract says its own children were accounted for.
    /// </summary>
    /// <remarks>
    /// <see cref="TimedOut"/> and <see cref="Abandoned"/> are the recorded facts
    /// that this witness was NOT obtained: the entry's own process exited or was
    /// killed, but a descendant may still hold its output pipes and still be
    /// writing into its root. Completion adoption is allowed only over a
    /// drain-witnessed outcome, so an entry whose tree could not be confirmed
    /// stopped is never later re-read as a finished, fully-accounted run - not on
    /// the live path and not on a rebuild that sees the same committed outcome.
    /// This is a positive test for the drained-and-stopped fact rather than a
    /// list of names to exclude: a future non-witnessed outcome is refused by
    /// default until it is added here deliberately.
    /// </remarks>
    internal static bool IsDrainWitnessed(string outcome) =>
        outcome is Complete or RunNotComplete;
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

    /// <summary>
    /// The ending the runner derived from the supervised run itself, captured
    /// before any completion adoption could overwrite <see cref="Outcome"/> with
    /// 'complete'. This is the immutable witness of whether the run's output
    /// drained to EOF and the supervised process exited: an adopted entry carries
    /// 'complete' in <see cref="Outcome"/> but keeps its pre-adoption ending here,
    /// so a later reader can tell an adoption that rested on that witness from one
    /// that never had it. A record from a build that did not persist this reads it
    /// as 'none', which is not drain-witnessed, so such an entry is never adopted
    /// as complete again.
    ///
    /// What the witness covers is bounded and is stated here rather than implied:
    /// the supervised process exited AND every descendant holding its inherited
    /// output handles released them. A descendant that never inherited those
    /// handles, or closed them before exiting, is outside it - no job object
    /// contains the tree, so such a descendant can outlive the ending. That
    /// residual is the reason the witness is recorded rather than assumed, but it
    /// is not eliminated by recording it.
    /// </summary>
    internal required string PreAdoptionOutcome { get; init; }

    internal required int ElapsedSeconds { get; init; }

    /// <summary>
    /// Real model subprocess starts this entry made, from its signed audit.
    /// Never a count of cycles, slots or reviewer processes.
    /// </summary>
    internal required int ModelStartCount { get; init; }

    /// <summary>
    /// Real model starts an interrupted entry may have made without recording
    /// them, bounded on the reviewed side from the run's own sealed plan. The
    /// global ceiling is checked against the sum of both.
    /// </summary>
    internal required int ModelStartUnmeasuredAllowance { get; init; }

    /// <summary>
    /// THE unit the verifier ceiling is spent in: one candidate paired with one
    /// required reciprocal model, read from the entry's signed audit. Never a
    /// count of terminal transitions.
    /// </summary>
    internal required int VerifierAssignmentCount { get; init; }

    /// <summary>
    /// Assignments an interrupted entry may have been given without sealing
    /// them. The ceiling is checked against the sum of both.
    /// </summary>
    internal required int VerifierAssignmentUnmeasuredAllowance { get; init; }

    internal required int SlotLaunchCount { get; init; }

    internal required int ProviderWriteCount { get; init; }

    internal required int WriteToolInvocationCount { get; init; }

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
        PreAdoptionOutcome = "none",
        ElapsedSeconds = 0,
        ModelStartCount = 0,
        ModelStartUnmeasuredAllowance = 0,
        VerifierAssignmentCount = 0,
        VerifierAssignmentUnmeasuredAllowance = 0,
        SlotLaunchCount = 0,
        ProviderWriteCount = 0,
        WriteToolInvocationCount = 0,
        AuditSha256 = "none",
        SummarySha256 = "none"
    };

    internal MapNode Describe()
    {
        var composed = new MapNode()
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
            .Set("outcome", Outcome);
        // Written only once there IS one, for the same reason registrySha256 is:
        // a record with no pre-adoption ending composes exactly the bytes it
        // composed before this field existed, so every journal signed by an
        // earlier build still authenticates and every cohort interrupted under
        // one can still be resumed. Composing 'none' instead would change the
        // signed bytes of every record ever written and turn a legitimate resume
        // into a tamper refusal, which is unrepairable by design. Every record
        // this build ends carries a real value, so presence is also the marker
        // that the witness was recorded at all.
        if (!string.Equals(PreAdoptionOutcome, "none", StringComparison.Ordinal))
        {
            composed.Set("preAdoptionOutcome", PreAdoptionOutcome);
        }
        return composed
            .Set("elapsedSeconds", ElapsedSeconds)
            .Set("modelStartCount", ModelStartCount)
            .Set("modelStartUnmeasuredAllowance", ModelStartUnmeasuredAllowance)
            .Set("verifierAssignmentCount", VerifierAssignmentCount)
            .Set("verifierAssignmentUnmeasuredAllowance", VerifierAssignmentUnmeasuredAllowance)
            .Set("slotLaunchCount", SlotLaunchCount)
            .Set("providerWriteCount", ProviderWriteCount)
            .Set("writeToolInvocationCount", WriteToolInvocationCount)
            .Set("auditSha256", AuditSha256)
            .Set("summarySha256", SummarySha256);
    }

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
            "preAdoptionOutcome",
            "elapsedSeconds",
            "modelStartCount",
            "modelStartUnmeasuredAllowance",
            "verifierAssignmentCount",
            "verifierAssignmentUnmeasuredAllowance",
            "slotLaunchCount",
            "providerWriteCount",
            "writeToolInvocationCount",
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
        // An ended entry with no audit digest is an entry nobody can account for:
        // what it consumed is unknown and its zero write counters were never
        // published by anything. This build never commits one except as the
        // refusal itself, so a record that says otherwise was written by
        // something else, and reading it would let the accounting walk past a
        // preparation on the strength of counters no evidence supports.
        var auditSha256 = StrictJson.RequireString(node, "auditSha256", label);
        if (string.Equals(state, CohortEntryStates.Ended, StringComparison.Ordinal)
            && string.Equals(auditSha256, "none", StringComparison.Ordinal)
            && !string.Equals(outcome, CohortEntryOutcomes.EvidenceRefused, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} says the entry ended '{outcome}' with no audit digest. An entry that published no evidence is refused " +
                "rather than accounted for, so this journal was not written by this build and is not resumed.");
        }

        // Optional on read, and absent reads as 'none' on purpose. A journal
        // written by a build that did not record the pre-adoption ending has no
        // such field; 'none' is not drain-witnessed, so an entry that build
        // adopted as 'complete' over an unconfirmed tree is not adopted again
        // rather than trusted on the word 'complete' alone. The completion is
        // dropped from the index rather than blocking it, because nothing about
        // such a record contradicts itself - the witness simply was never taken.
        var preAdoptionOutcome = "none";
        if (node.TryGetProperty("preAdoptionOutcome", out var preAdoptionNode))
        {
            if (preAdoptionNode.ValueKind != JsonValueKind.String)
            {
                throw new ContractException($"The {label} field 'preAdoptionOutcome' is a {StrictJson.Describe(preAdoptionNode.ValueKind)}, not a string.");
            }
            preAdoptionOutcome = preAdoptionNode.GetString()!;
            // A literally-present 'none' is refused rather than accepted,
            // because the writer OMITS the field at that value: accepting it
            // would load a journal that then fails its own signature and be
            // reported as tampering no operator could repair. The mirror of the
            // writable bound below - a value only the reader accepts is as
            // wedging as a value only the reader refuses.
            if (string.Equals(preAdoptionOutcome, "none", StringComparison.Ordinal))
            {
                throw new ContractException(
                    $"The {label} records preAdoptionOutcome 'none' as a field. A record with no pre-adoption ending omits the " +
                    "field entirely, so a journal that writes it out cannot reproduce the signature it was written with.");
            }
            if (!CohortEntryOutcomes.IsKnown(preAdoptionOutcome))
            {
                throw new ContractException($"The {label} records preAdoptionOutcome '{preAdoptionOutcome}', which is not an outcome this build writes.");
            }
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
            PreAdoptionOutcome = preAdoptionOutcome,
            ElapsedSeconds = StrictJson.RequireInt(node, "elapsedSeconds", label, 0, int.MaxValue),
            ModelStartCount = StrictJson.RequireInt(node, "modelStartCount", label, 0, int.MaxValue),
            ModelStartUnmeasuredAllowance = StrictJson.RequireInt(node, "modelStartUnmeasuredAllowance", label, 0, int.MaxValue),
            VerifierAssignmentCount = StrictJson.RequireInt(node, "verifierAssignmentCount", label, 0, int.MaxValue),
            VerifierAssignmentUnmeasuredAllowance = StrictJson.RequireInt(node, "verifierAssignmentUnmeasuredAllowance", label, 0, int.MaxValue),
            SlotLaunchCount = StrictJson.RequireInt(node, "slotLaunchCount", label, 0, int.MaxValue),
            ProviderWriteCount = StrictJson.RequireInt(node, "providerWriteCount", label, 0, int.MaxValue),
            WriteToolInvocationCount = StrictJson.RequireInt(node, "writeToolInvocationCount", label, 0, int.MaxValue),
            AuditSha256 = auditSha256,
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
    internal const string ContractVersionValue = "devpilot.shadow-cohort.journal.v3";
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

    /// <summary>
    /// The word this cohort last published about itself, or "none" when it has
    /// published nothing.
    /// </summary>
    /// <remarks>
    /// A rebuild cannot derive this from the entry records alone. A cohort with
    /// entries still pending may have stopped because a budget ceiling was
    /// reached, because an entry's launch could not be resolved, because the
    /// manifest was refused, or because the runner was killed - and those are
    /// four different accounts of the same set of records. So the word and the
    /// closed phrase beside it are committed into the signed journal when they
    /// are published, and a rebuild reads them back rather than guessing.
    /// </remarks>
    internal string TerminalReason { get; private set; } = "none";

    internal string TerminalDetail { get; private set; } = "none";

    internal string TerminalDetailSha256 { get; private set; } = "none";

    /// <summary>True when this journal carries a published word about the cohort as a whole.</summary>
    internal bool HasTerminal => !string.Equals(TerminalReason, "none", StringComparison.Ordinal);

    /// <summary>
    /// The registry revision this cohort has accepted, or "none" before it has
    /// verified one.
    /// </summary>
    internal string RegistrySha256 { get; private set; } = "none";

    /// <summary>
    /// Commits the registry revision this cohort now stands on.
    /// </summary>
    /// <remarks>
    /// Committed AFTER the registry file it names has been written, so a runner
    /// killed between the two leaves a journal naming the previous revision beside
    /// a registry holding the new one. That pair is resolvable: the sample the
    /// registry gained is keyed by the run that produced it, so the resume records
    /// the same sample again and lands on the same bytes. The opposite order would
    /// leave a journal naming a revision that does not exist.
    /// </remarks>
    internal void RecordRegistryRevision(byte[] key, string registrySha256)
    {
        if (string.Equals(RegistrySha256, registrySha256, StringComparison.Ordinal))
        {
            return;
        }
        var previous = RegistrySha256;
        var previousSequence = Sequence;
        RegistrySha256 = registrySha256;
        Sequence++;
        _events.Add(new MapNode()
            .Set("sequence", Sequence)
            .Set("atUtc", DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture))
            .Set("entryId", "none")
            .Set("kind", "registry")
            .Set("detail", "the cohort accepted a registry revision"));
        try
        {
            Save(key);
        }
        catch
        {
            _events.RemoveAt(_events.Count - 1);
            RegistrySha256 = previous;
            Sequence = previousSequence;
            throw;
        }
    }

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
        return RandomNumberGenerator.GetBytes(CoordinatorState.SigningKeyLength);
    }

    /// <summary>
    /// True when this root records work this run cannot account for.
    /// </summary>
    /// <remarks>
    /// An intent is written before every attempt and never removed, and an index
    /// is published before the first entry is reached, so a root holding either
    /// has started something. This is what separates "a first run died before its
    /// journal reached the disk" from "somebody removed the journal", which are
    /// otherwise the same two files on disk. A root whose journal, intents and
    /// index have ALL been removed is a fresh root by construction, and the
    /// per-entry preparation refuses on its own to start over an output root that
    /// still holds standing work.
    /// </remarks>
    private static bool HasRecordedWork(CohortManifest manifest) =>
        (Directory.Exists(manifest.IntentRoot)
            && Directory.EnumerateFiles(manifest.IntentRoot, "*.intent.json", SearchOption.TopDirectoryOnly).Any())
        || File.Exists(manifest.IndexPath);

    private static byte[] ReadKey(CohortManifest manifest) =>
        // Legacy hexadecimal is accepted here and only here: a cohort root
        // written by an earlier build holds one, and an operator resuming that
        // root must not be told its own journal is unreadable. What this build
        // writes is the raw key every other signature in this program is checked
        // against.
        CoordinatorState.ReadSigningKey(manifest.JournalKeyPath, "cohort journal key", allowLegacyHex: true);

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
            // nothing, so it also wrote no launch intent and published no index,
            // and a root holding neither has demonstrably started nothing. The
            // refusal happens here, before anything is mutated.
            if (keyPreexisted && HasRecordedWork(manifest))
            {
                throw new ContractException(
                    $"The cohort journal root '{manifest.JournalRoot}' carries a signing key and no journal at '{manifest.JournalPath}', " +
                    "and this root records work this run cannot account for. " +
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
            "terminal",
            "registrySha256",
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

        var terminal = StrictJson.RequireObject(root, "terminal", Label);
        StrictJson.RequireNoUnknownFields(terminal, Label + " terminal", "reason", "detail", "detailSha256");
        var terminalReason = StrictJson.RequireString(terminal, "reason", Label + " terminal");
        if (!string.Equals(terminalReason, "none", StringComparison.Ordinal) && !CohortIndex.IsKnownReason(terminalReason))
        {
            throw new ContractException($"The {Label} records terminal reason '{terminalReason}', which is not a reason this build publishes.");
        }
        var terminalDetailSha256 = StrictJson.RequireString(terminal, "detailSha256", Label + " terminal");
        if (!string.Equals(terminalDetailSha256, "none", StringComparison.Ordinal)
            && (terminalDetailSha256.Length != 64 || !StrictJson.IsLowerHex(terminalDetailSha256)))
        {
            throw new ContractException($"The {Label} terminal detail digest is neither 'none' nor 64 lower-case hexadecimal characters.");
        }
        journal.TerminalReason = terminalReason;
        journal.TerminalDetail = StrictJson.RequireString(terminal, "detail", Label + " terminal");
        journal.TerminalDetailSha256 = terminalDetailSha256;

        // Absent means 'this cohort has never accepted a registry revision', which
        // is exactly what every journal written before the account existed says.
        // Reading it as a required field would make those journals unreadable, and
        // an unreadable journal is an unresumable cohort - so a historical root
        // would become unrecoverable evidence rather than evidence.
        var registrySha256 = "none";
        if (root.TryGetProperty("registrySha256", out _))
        {
            registrySha256 = StrictJson.RequireString(root, "registrySha256", Label);
        }
        if (!string.Equals(registrySha256, "none", StringComparison.Ordinal)
            && (registrySha256.Length != 64 || !StrictJson.IsLowerHex(registrySha256)))
        {
            throw new ContractException($"The {Label} records a registry revision that is neither 'none' nor 64 lower-case hexadecimal characters.");
        }
        journal.RegistrySha256 = registrySha256;

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
    /// Commits the word this cohort is publishing about itself, so a rebuild
    /// reads it back rather than inferring it.
    /// </summary>
    /// <remarks>
    /// Written before the index it describes, so a runner killed between the two
    /// leaves a journal that already says what the missing index would have said
    /// and a rebuild reproduces it. Unchanged is a no-op, because a cohort that
    /// republished the same word on every entry would rewrite the journal for
    /// nothing.
    /// </remarks>
    internal void RecordTerminal(byte[] key, string reason, string detail, string detailSha256)
    {
        if (string.Equals(TerminalReason, reason, StringComparison.Ordinal)
            && string.Equals(TerminalDetail, detail, StringComparison.Ordinal)
            && string.Equals(TerminalDetailSha256, detailSha256, StringComparison.Ordinal))
        {
            return;
        }
        if (!CohortIndex.IsKnownReason(reason))
        {
            throw new ContractException($"A cohort cannot publish terminal reason '{reason}'; it is not a reason this build writes.");
        }
        var previousReason = TerminalReason;
        var previousDetail = TerminalDetail;
        var previousDigest = TerminalDetailSha256;
        var previousSequence = Sequence;
        TerminalReason = reason;
        TerminalDetail = detail;
        TerminalDetailSha256 = detailSha256;
        Sequence++;
        _events.Add(new MapNode()
            .Set("sequence", Sequence)
            .Set("atUtc", DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture))
            .Set("entryId", "none")
            .Set("kind", "terminal")
            .Set("detail", reason));
        try
        {
            Save(key);
        }
        catch
        {
            _events.RemoveAt(_events.Count - 1);
            TerminalReason = previousReason;
            TerminalDetail = previousDetail;
            TerminalDetailSha256 = previousDigest;
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
        // The rest of the reader's bounds, applied in the reader's own order, so
        // the writer can never produce an account that loads back as a refusal.
        RequireInRange(record, "ordinal", record.Ordinal, 1, 64);
        RequireInRange(record, "attempt", record.Attempt, 0, MaximumAttempts);
        RequireInRange(record, "childProcessId", record.ChildProcessId, 0, int.MaxValue);
        RequireInRange(record, "elapsedSeconds", record.ElapsedSeconds, 0, int.MaxValue);
        RequireInRange(record, "modelStartCount", record.ModelStartCount, 0, int.MaxValue);
        RequireInRange(record, "modelStartUnmeasuredAllowance", record.ModelStartUnmeasuredAllowance, 0, int.MaxValue);
        RequireInRange(record, "verifierAssignmentCount", record.VerifierAssignmentCount, 0, int.MaxValue);
        RequireInRange(record, "verifierAssignmentUnmeasuredAllowance", record.VerifierAssignmentUnmeasuredAllowance, 0, int.MaxValue);
        RequireInRange(record, "slotLaunchCount", record.SlotLaunchCount, 0, int.MaxValue);
        RequireInRange(record, "providerWriteCount", record.ProviderWriteCount, 0, int.MaxValue);
        RequireInRange(record, "writeToolInvocationCount", record.WriteToolInvocationCount, 0, int.MaxValue);
        RequireSpoken(record, "entryId", record.EntryId);
        RequireSpoken(record, "intentSha256", record.IntentSha256);
        RequireSpoken(record, "startedAtUtc", record.StartedAtUtc);
        RequireSpoken(record, "endedAtUtc", record.EndedAtUtc);
        RequireSpoken(record, "auditSha256", record.AuditSha256);
        RequireSpoken(record, "summarySha256", record.SummarySha256);
        if (!CohortEntryStates.IsKnown(record.State))
        {
            throw new ContractException($"Entry '{record.EntryId}' would be committed in state '{record.State}', which is not a state this build writes.");
        }
        if (!string.Equals(record.Outcome, "none", StringComparison.Ordinal) && !CohortEntryOutcomes.IsKnown(record.Outcome))
        {
            throw new ContractException($"Entry '{record.EntryId}' would be committed with outcome '{record.Outcome}', which is not an outcome this build writes.");
        }
        // The same bound the reader applies to the pre-adoption ending, applied
        // here first. A value only the reader refuses would produce a journal
        // that saves and then will not load, and a journal that will not load
        // cannot be repaired.
        if (!string.Equals(record.PreAdoptionOutcome, "none", StringComparison.Ordinal)
            && !CohortEntryOutcomes.IsKnown(record.PreAdoptionOutcome))
        {
            throw new ContractException($"Entry '{record.EntryId}' would be committed with pre-adoption outcome '{record.PreAdoptionOutcome}', which is not an outcome this build writes.");
        }
        if (record.HasEnded && string.Equals(record.Outcome, "none", StringComparison.Ordinal))
        {
            throw new ContractException($"Entry '{record.EntryId}' would be committed as ended with no outcome; an ending is the outcome it recorded.");
        }
        if (record.HasEnded
            && string.Equals(record.AuditSha256, "none", StringComparison.Ordinal)
            && !record.EndedRefused)
        {
            throw new ContractException(
                $"Entry '{record.EntryId}' would be committed as ended '{record.Outcome}' with no audit digest. An entry that published " +
                "no evidence is closed as refused and stops the cohort; committing it as an ordinary ending would put counters no " +
                "evidence supports into a signed account.");
        }
    }

    private static void RequireInRange(CohortEntryRecord record, string field, int value, int low, int high)
    {
        if (value < low || value > high)
        {
            throw new ContractException(
                $"Entry '{record.EntryId}' would be committed with '{field}' of {value.ToString(CultureInfo.InvariantCulture)}, " +
                $"outside the {low.ToString(CultureInfo.InvariantCulture)} to {high.ToString(CultureInfo.InvariantCulture)} " +
                "the reader admits. A record the reader refuses cannot be written into a signed journal.");
        }
    }

    private static void RequireSpoken(CohortEntryRecord record, string field, string value)
    {
        if (value.Length == 0)
        {
            throw new ContractException(
                $"Entry '{record.EntryId}' would be committed with an empty '{field}'. Absent is written as 'none' so that the reader " +
                "admits it; an empty string is a record this journal could not load back.");
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
            stream.Write(key, 0, key.Length);
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
        var composed = new MapNode()
            .Set("contractVersion", ContractVersionValue)
            .Set("kind", KindValue)
            .Set("cohortId", _manifest.CohortId)
            .Set("manifestSha256", _manifest.ManifestSha256)
            .Set("bindingSha256", BindingSha256)
            .Set("sequence", Sequence)
            .Set("entries", entries)
            .Set("events", events)
            .Set("terminal", new MapNode()
                .Set("reason", TerminalReason)
                .Set("detail", TerminalDetail)
                .Set("detailSha256", TerminalDetailSha256));
        // The registry revision this cohort last accepted or produced. A cohort
        // that records a subject moves the registry forward, so the revision the
        // manifest bound is no longer the revision on disk - and a resume that
        // insisted on the bound one would refuse its own work. Kept here rather
        // than inferred, so the acceptable revisions are exactly two: the one
        // declared and the one this cohort itself wrote.
        //
        // Written only once there IS one. A cohort that has accepted no revision
        // composes exactly the bytes it composed before this field existed, so
        // every journal signed by an earlier build still authenticates and every
        // cohort interrupted under one can still be resumed. Presence is the
        // version marker; there is no separate number to keep in step.
        if (!string.Equals(RegistrySha256, "none", StringComparison.Ordinal))
        {
            composed.Set("registrySha256", RegistrySha256);
        }
        return composed;
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
        if (record.ChildProcessId <= 0 || !IsUsableStartTime(record.ChildStartedAtUtc))
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
    /// True when a recorded child start time is one this build could have
    /// written, and could therefore compare a live process against.
    /// </summary>
    /// <remarks>
    /// A start time that is absent, sentinel, or simply not a round-trip instant
    /// cannot be compared with a candidate process's own start time. Treating an
    /// uncomparable time as a mismatch would read as "that child is gone", which
    /// is the one answer that starts a second preparation against a live output
    /// root. So it is uncomparable here and unresolved at the caller.
    /// </remarks>
    internal static bool IsUsableStartTime(string startedAtUtc) =>
        startedAtUtc.Length != 0
        && !string.Equals(startedAtUtc, "none", StringComparison.Ordinal)
        && DateTime.TryParseExact(
            startedAtUtc,
            "O",
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out _);

    /// <summary>
    /// True when the exact recorded child is still running. A matching identifier
    /// whose start time differs is a recycled identifier and is deliberately not
    /// the child.
    /// </summary>
    internal static bool IsRecordedChildAlive(CohortEntryRecord record)
    {
        if (record.ChildProcessId <= 0 || !IsUsableStartTime(record.ChildStartedAtUtc))
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
