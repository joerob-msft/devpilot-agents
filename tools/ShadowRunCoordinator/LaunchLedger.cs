using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// A launch that was intended but whose outcome this root cannot account for.
/// </summary>
/// <remarks>
/// Its own type because it is not a contract fault of the request and not a
/// failure of a child: it is the one answer a crash-consistent control plane is
/// allowed to give when it genuinely does not know, and the entry point maps it
/// to the refusal exit code rather than letting it read as a child that failed.
/// </remarks>
internal sealed class UnresolvedLaunchException(string message) : Exception(message);

/// <summary>
/// What one launch is for. Bound by the caller BEFORE the launch, so the intent
/// record names the transition and the run-set position a later reader has to
/// place it in rather than a step name on its own.
/// </summary>
internal sealed record LaunchBinding(string Transition, string SetId, string SlotName, string ExpectedTerminalPath)
{
    internal static readonly LaunchBinding None = new(string.Empty, string.Empty, string.Empty, string.Empty);
}

/// <summary>One committed launch intent, as the ledger handed it back.</summary>
internal sealed record LaunchIntent(string Step, int Attempt, long LaunchSequence, string Path, string ChildSpecSha256);

/// <summary>What a standing intent for one step says, once its signature held.</summary>
internal sealed record StandingIntent(
    string Step,
    int Attempt,
    long LaunchSequence,
    string Phase,
    string Path,
    int ChildProcessId,
    string ChildStartedAtUtc);

/// <summary>
/// The signed record of every child this output root ever intended to start.
/// </summary>
/// <remarks>
/// The journal beside a child says what is running now; this ledger says what
/// was ever meant to run, and it is written one step earlier - before the
/// process exists at all.
///
/// That ordering is the whole point. <see cref="Process.Start(ProcessStartInfo)"/>
/// creates the process before it returns, so a coordinator killed in the instant
/// between the call and the record of its result leaves a live child nothing on
/// disk names. Committing the intent first turns that instant from a window in
/// which a duplicate launch can happen into a window in which the OUTCOME is
/// unknown - and an unknown outcome is refused, never retried. So:
///
///   no intent for a step          the child provably never started, launch it;
///   intent, phase 'notStarted'    the start itself failed, launch it again;
///   intent, phase 'intended'      unknown - a process may exist that nothing
///                                 can name. Refuse. Never launch a second one;
///   intent, phase 'started'       the child existed and is identified. Launch
///                                 again only once it is provably gone;
///   intent, phase 'abandoned'     the child was told to stop and its exit was
///                                 never confirmed. Same rule as 'started';
///   intent, phase 'closed'        accounted for, the step may be attempted again.
///
/// Two of those rules consult the operating system rather than the record alone,
/// and they have to. A coordinator killed between recording a pid and recording
/// anything else leaves a LIVE child that the ordinary liveness check - which
/// reads the child journal - cannot see, because the journal entry naming that
/// child is written after the ledger's. The pid and start time in the intent are
/// the only account of it, so they are the ones asked.
///
/// The one deliberate relaxation is the read-only prelaunch probe. Its whole
/// output is a set of digests and existence flags, the machine deletes its
/// previous answer before every attempt, and it publishes nothing. Refusing a
/// root forever over an ambiguous probe would discard a completed, non-repeatable
/// slot run to protect a step that costs nothing to repeat, so a probe whose
/// process is not alive may be attempted again. Every other step keeps the
/// unconditional refusal.
///
/// Records are signed with the coordinator state key and replaced atomically, so
/// a truncated or edited intent is not believed - and because "not believed" here
/// means "cannot be accounted for", an unverifiable intent refuses exactly as an
/// open one does. Fail closed is the only safe direction: the cost of refusing is
/// an operator running again on a fresh root, and the cost of guessing is two
/// reviewers writing one output root.
/// </remarks>
internal sealed class LaunchLedger(CoordinatorRequest request, byte[] stateKey, bool keyPreexisted = true)
{
    internal const string ContractVersion = "devpilot.shadow-run-coordinator.launch-intent.v1";

    /// <summary>Committed before the process exists. The only ambiguous phase there is.</summary>
    internal const string PhaseIntended = "intended";

    /// <summary>The start itself failed, so nothing was created. Provably no child.</summary>
    internal const string PhaseNotStarted = "notStarted";

    /// <summary>The process exists and its identity is durable.</summary>
    internal const string PhaseStarted = "started";

    /// <summary>
    /// The child was told to stop and its exit was never confirmed. Killing a
    /// process tree is best effort, so this is what a step that could not prove
    /// its child is gone leaves behind: an account, rather than the silence a
    /// 'closed' record would have amounted to.
    /// </summary>
    internal const string PhaseAbandoned = "abandoned";

    /// <summary>The launch was observed to an end this root has recorded.</summary>
    internal const string PhaseClosed = "closed";

    private const string Label = "launch intent";

    private const int MaximumBytes = 64 * 1024;

    private readonly CoordinatorRequest _request = request;
    private readonly byte[] _stateKey = stateKey;

    /// <summary>
    /// Whether the signing key existed before this run, and so whether any record
    /// in this root was written under the key this ledger reads with.
    /// </summary>
    private readonly bool _keyPreexisted = keyPreexisted;

    /// <summary>What the next launch is for. Set by the caller before it launches.</summary>
    internal LaunchBinding Binding { get; set; } = LaunchBinding.None;

    /// <summary>Intents this process committed, as opposed to ones it found.</summary>
    internal int OpenedCount { get; private set; }

    /// <summary>Launches this process observed a process identity for.</summary>
    internal int StartedCount { get; private set; }

    /// <summary>
    /// Refuses to launch when the last intent for this step cannot be accounted
    /// for. Called immediately before every launch, and again from the machine at
    /// the top of the two irreversible ones, so an ambiguous window is reported
    /// as an ambiguous window rather than as whatever it happens to trip over
    /// next.
    /// </summary>
    internal void RequireLaunchable(string step)
    {
        var standing = ReadStanding(step);
        if (standing is null || standing.Phase is PhaseClosed or PhaseNotStarted)
        {
            return;
        }

        // Asked of the operating system, not of the record. A child recorded here
        // and nowhere else is invisible to every other liveness check this root
        // has, so this is the only place that can refuse over it.
        if (IsRecordedChildAlive(standing))
        {
            throw new UnresolvedLaunchException(
                $"The '{step}' step left a child (process {standing.ChildProcessId.ToString(CultureInfo.InvariantCulture)}, started {standing.ChildStartedAtUtc}) " +
                "that is still running and is not this coordinator's. A second one is not started while the first is alive. " +
                "Stop that process, or use a fresh output root.");
        }

        // Started, or told to stop without a confirmed exit, and provably gone.
        // What it did is now a question about the artifacts it wrote, which the
        // ordinary resume rules answer; it is not an unaccounted-for launch.
        if (standing.Phase is PhaseStarted or PhaseAbandoned)
        {
            return;
        }

        // The read-only probe. Repeating it costs nothing and wedging the root
        // over it would cost a completed slot run.
        if (IsRepeatable(step))
        {
            return;
        }

        throw new UnresolvedLaunchException(
            $"The '{step}' step committed an intent to launch (sequence {standing.LaunchSequence.ToString(CultureInfo.InvariantCulture)}, attempt {standing.Attempt.ToString(CultureInfo.InvariantCulture)}) " +
            $"and this output root holds no record of what that launch became. A process may exist that nothing here can name, " +
            "so a second one is not started. This root is not resumable; use a fresh output root.");
    }

    /// <summary>
    /// Refuses to do anything at all while any step's launch is unaccounted for.
    /// </summary>
    /// <remarks>
    /// The per-step gate above is asked only of steps this run is about to
    /// launch, and a run resuming a root whose ranks are already committed
    /// launches nothing - so without this, a root carrying an open intent could
    /// complete and publish an audit whose own census contradicts it. Asked once,
    /// at the top of the run, so the refusal is the first thing that happens
    /// rather than something a later step stumbles into.
    ///
    /// It is asked only of a root whose signing KEY predates this run. When the
    /// key was minted here, no record in this root was written under it, so an
    /// intent that does not verify is not evidence of an unaccounted launch - it
    /// is evidence that the key is gone, which is a whole-root condition the
    /// coordinator already refuses over with the side effect it can actually
    /// point at. Refusing here instead would replace a refusal that names the
    /// standing snapshot with one that names nothing, and would wedge a fresh
    /// root over records it cannot read. The case this gate exists for - a key
    /// that IS present and a record that is open or damaged under it - is
    /// untouched by the exemption.
    /// </remarks>
    internal void RequireNothingUnaccounted()
    {
        if (!_keyPreexisted)
        {
            return;
        }
        foreach (var standing in ReadAll())
        {
            if (standing.Phase is PhaseClosed or PhaseNotStarted or PhaseStarted or PhaseAbandoned)
            {
                continue;
            }
            if (IsRepeatable(standing.Step) && !IsRecordedChildAlive(standing))
            {
                continue;
            }
            throw new UnresolvedLaunchException(
                $"The '{standing.Step}' step committed an intent to launch and this output root holds no record of what that launch became. " +
                "A process may exist that nothing here can name, so this run does nothing. " +
                "This root is not resumable; use a fresh output root.");
        }
    }

    /// <summary>
    /// True for the steps that publish nothing and may safely be attempted again.
    /// </summary>
    /// <remarks>
    /// Decided by the step name rather than by a flag in the record, and that is
    /// deliberate: repeatability is a property of the STEP, so a record too
    /// damaged to read cannot lie about it. The prelaunch probes are the only
    /// children the machine runs whose previous answer it deletes before every
    /// attempt precisely because that answer is worthless by definition.
    /// </remarks>
    internal static bool IsRepeatable(string step) =>
        step.EndsWith("Prelaunch", StringComparison.Ordinal);

    /// <summary>
    /// Whether the process an intent names is provably the one it named. An
    /// unreadable identity is not a match, so this never claims a recycled id.
    /// </summary>
    private static bool IsRecordedChildAlive(StandingIntent standing) =>
        standing.ChildProcessId > 0
        && standing.ChildStartedAtUtc.Length > 0
        && ChildJournal.IsAlive(new RecordedChild(standing.Step, standing.ChildProcessId, standing.ChildStartedAtUtc, standing.Path));

    /// <summary>
    /// Commits the intent to start one child, and returns once it is on disk.
    /// Nothing is started here.
    /// </summary>
    internal LaunchIntent Open(
        string step,
        string childRequestSha256,
        ProcessStartInfo start,
        string requestPath,
        string expectedResultPath)
    {
        RequireLaunchable(step);
        Directory.CreateDirectory(_request.LaunchIntentRoot);
        var attempt = NextAttempt(step);
        var launchSequence = NextLaunchSequence();
        // The identity of the COMMAND, taken over the exact things that decide
        // what runs: the executable, every argument in order, and the directory
        // it runs in. A record that named only the script would not notice a
        // changed argument list, and the argument list is where the request path
        // - the child's entire input - is carried.
        var spec = new MapNode()
            .Set("fileName", start.FileName)
            .Set("workingDirectory", start.WorkingDirectory);
        var arguments = new ListNode();
        foreach (var argument in start.ArgumentList)
        {
            arguments.Add(Node.Text(argument));
        }
        spec.Set("arguments", arguments);
        var childSpecSha256 = CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(spec));

        var path = IntentPath(step, attempt);
        var record = Compose(
            step,
            attempt,
            launchSequence,
            childRequestSha256,
            childSpecSha256,
            requestPath,
            expectedResultPath);
        WriteSigned(path, record);
        OpenedCount++;
        return new LaunchIntent(step, attempt, launchSequence, path, childSpecSha256);
    }

    /// <summary>
    /// Records the exact process an intent became, the moment it exists. This is
    /// the second half of the two-record launch: after it, a later run can name
    /// what this one left behind; before it, it cannot.
    /// </summary>
    internal void RecordStart(LaunchIntent intent, Process process)
    {
        Rewrite(intent.Path, PhaseStarted, map => map
            .Set("childProcessId", process.Id)
            .Set("childStartedAtUtc", ChildJournal.StartedAtUtc(process)));
        StartedCount++;
    }

    /// <summary>
    /// Records that the start itself failed, which is the one way an intent can
    /// be closed with certainty that no process was created.
    /// </summary>
    /// <remarks>
    /// Guarded for the same reason <see cref="Account"/> is: every caller of this
    /// reaches it from inside a catch block that is about to rethrow, so an
    /// exception escaping here would REPLACE the fault being reported - a child
    /// that could not be started would surface as an unhandled storage crash
    /// instead of the typed child failure the exit codes are built on. A record
    /// left at 'intended' is the conservative reading the gates already refuse
    /// over, so failing to write this loses nothing but precision.
    /// </remarks>
    internal void RecordNotStarted(LaunchIntent intent, string reason)
    {
        try
        {
            Rewrite(intent.Path, PhaseNotStarted, map => map.Set("terminalReason", Truncate(reason)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ContractException)
        {
        }
    }

    /// <summary>
    /// Accounts for the standing intent of a step. Addressed by step rather than
    /// by handle so that a run which ADOPTED a child a previous process started
    /// closes the intent that process opened, instead of leaving it open forever.
    /// </summary>
    internal void Close(string step, string outcome, string terminalReason) =>
        Account(step, PhaseClosed, outcome, terminalReason);

    /// <summary>
    /// Accounts for a step whose child was told to stop and whose exit was never
    /// confirmed.
    /// </summary>
    /// <remarks>
    /// Killing a process tree is best effort by construction, so "the kill call
    /// returned" is not "the child is gone". Recording that as 'closed' would say
    /// the step may be attempted again while a writer of this output root may
    /// still be alive - which is the duplicate launch this ledger exists to
    /// prevent, arrived at through the cleanup path instead of the crash path.
    /// The distinct phase keeps the fact, and the launch gate re-asks the
    /// operating system rather than trusting either answer.
    /// </remarks>
    internal void Abandon(string step, string terminalReason) =>
        Account(step, PhaseAbandoned, "abandoned", terminalReason);

    /// <summary>
    /// The one writer of a terminal phase. Every read it needs is inside the
    /// guard, because both callers call it from a <c>finally</c>: an exception
    /// escaping here would replace the exception the step was already reporting,
    /// turning a clean child failure into an unhandled crash.
    /// </summary>
    private void Account(string step, string phase, string outcome, string terminalReason)
    {
        try
        {
            var standing = ReadStanding(step);
            if (standing is null || standing.Phase == PhaseClosed || standing.Phase == PhaseAbandoned)
            {
                return;
            }
            // An intent whose own record does not verify is not accounted for,
            // and that is not an oversight: rewriting a record this run cannot
            // read is exactly the act of manufacturing an account of a launch
            // nobody witnessed. It stays unaccounted for, and the next run
            // refuses rather than launching a second child.
            if (Read(standing.Path) is null)
            {
                return;
            }
            Rewrite(standing.Path, phase, map => map
                .Set("outcome", outcome)
                .Set("terminalReason", Truncate(terminalReason)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ContractException)
        {
            // A step that finished must not be turned into a failed one because
            // its accounting could not be written. The record stays open, which
            // is the conservative reading: the next run refuses rather than
            // launching a second child.
        }
    }

    /// <summary>The standing intent for a step, or null when there is none this run can account for.</summary>
    internal StandingIntent? ReadStanding(string step)
    {
        StandingIntent? latest = null;
        foreach (var path in EnumerateIntentFiles(Stem(step) + "-*.intent.json"))
        {
            var record = Read(path);
            if (record is null)
            {
                // An intent that does not verify is an intent that cannot be
                // accounted for, and is deliberately reported as the open case
                // rather than skipped: skipping it would let a truncated record
                // authorize the second launch the whole ledger exists to prevent.
                return new StandingIntent(step, 0, 0, PhaseIntended, path, 0, string.Empty);
            }
            if (!string.Equals(record.Step, step, StringComparison.Ordinal))
            {
                continue;
            }
            if (latest is null || record.Attempt > latest.Attempt)
            {
                latest = record;
            }
        }
        return latest;
    }

    /// <summary>
    /// Every intent this root holds, newest first, for the audit. Read from disk
    /// rather than from this process, so a resumed run publishes the same census
    /// an uninterrupted one does.
    /// </summary>
    internal IReadOnlyList<StandingIntent> ReadAll()
    {
        var all = new List<StandingIntent>();
        foreach (var path in EnumerateIntentFiles("*.intent.json"))
        {
            var record = Read(path);
            all.Add(record ?? new StandingIntent(StepFromFileName(path), 0, 0, PhaseIntended, path, 0, string.Empty));
        }
        all.Sort(static (left, right) => left.LaunchSequence.CompareTo(right.LaunchSequence));
        return all;
    }

    /// <summary>
    /// The intent files matching a pattern, materialised before anything reads
    /// them.
    /// </summary>
    /// <remarks>
    /// <see cref="Directory.EnumerateFiles(string, string, SearchOption)"/> is
    /// lazy, so a storage fault surfaces from the middle of whatever loop is
    /// walking it - including one inside a <c>finally</c>. Materialising here
    /// keeps that fault where it can be reasoned about, and an unreadable
    /// directory is reported as no files rather than as a crash, because the
    /// gates above already treat "cannot be accounted for" as the refusing case.
    /// </remarks>
    private IReadOnlyList<string> EnumerateIntentFiles(string pattern)
    {
        if (!Directory.Exists(_request.LaunchIntentRoot))
        {
            return [];
        }
        try
        {
            return Directory.GetFiles(_request.LaunchIntentRoot, pattern, SearchOption.TopDirectoryOnly);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>
    /// The step an unreadable intent belongs to, taken from its file name.
    /// </summary>
    /// <remarks>
    /// A record too damaged to verify still has to be reported against the step
    /// it names, because the census is what an operator reads to find out which
    /// step is holding the root closed. The name is written by this class alone
    /// and is structured, so recovering the step from it is not a parse of
    /// untrusted text; anything that does not match the shape is reported whole.
    /// </remarks>
    private string StepFromFileName(string path)
    {
        var name = Path.GetFileName(path);
        var prefix = _request.CorrelationId + "-";
        const string suffix = ".intent.json";
        if (!name.StartsWith(prefix, StringComparison.Ordinal) || !name.EndsWith(suffix, StringComparison.Ordinal))
        {
            return name;
        }
        var middle = name[prefix.Length..^suffix.Length];
        var separator = middle.LastIndexOf('-');
        return separator <= 0 ? name : middle[..separator];
    }

    /// <summary>The census the audit publishes: how many launches, and how many are unaccounted for.</summary>
    internal MapNode DescribeCensus()
    {
        var records = ReadAll();
        var started = 0;
        var unresolved = new ListNode();
        var abandoned = 0;
        foreach (var record in records)
        {
            if (record.Phase is PhaseStarted or PhaseClosed or PhaseAbandoned && record.ChildProcessId != 0)
            {
                started++;
            }
            if (record.Phase == PhaseAbandoned)
            {
                abandoned++;
            }
            if (record.Phase == PhaseIntended)
            {
                unresolved.Add(Node.Text(record.Step));
            }
        }
        return new MapNode()
            .Set("intentCount", records.Count)
            .Set("startedCount", started)
            .Set("abandonedCount", abandoned)
            .Set("unresolvedSteps", unresolved);
    }

    /// <summary>
    /// Amends a record that this run has already verified, and re-signs it.
    /// </summary>
    /// <remarks>
    /// The verification is not a formality. Re-signing whatever bytes happen to
    /// be at the path would take a record that was swapped, truncated or edited
    /// during the very window this ledger protects - between the intent and the
    /// account of what it became - and hand it back this coordinator's signature,
    /// after which it verifies forever. So an unreadable record is left exactly
    /// as it is: unaccounted for, and refusing.
    /// </remarks>
    private void Rewrite(string path, string phase, Func<MapNode, MapNode> amend)
    {
        if (Read(path, out var verified) is null || verified is null)
        {
            return;
        }
        // The map that was PROVEN, not a second read of the same path. Reading
        // twice would verify one set of bytes and sign another, so anything that
        // replaced the file between the two - in the very window this ledger
        // exists to protect - would be handed this coordinator's signature and
        // verify forever after.
        verified.Set("phase", phase);
        amend(verified);
        WriteSigned(path, verified);
    }

    /// <summary>
    /// Signs a record over everything in it except the signature, and replaces
    /// the file atomically. Both halves matter: the signature is what stops an
    /// edited intent being believed, and the atomic replace is what stops a
    /// coordinator killed mid-write leaving half a record, which would read as an
    /// unverifiable one and wedge the root for a reason that never happened.
    /// </summary>
    private void WriteSigned(string path, MapNode record)
    {
        record.Remove("signature");
        var signature = CanonicalJson.HmacHex(_stateKey, CanonicalJson.Canonical(record));
        record.Set("signature", new MapNode().Set("algorithm", "HMACSHA256").Set("value", signature));
        CanonicalJson.WriteFileAtomic(path, CanonicalJson.Readable(record));
    }

    /// <summary>One intent record, or null when it is not this root's or does not verify.</summary>
    private StandingIntent? Read(string path) => Read(path, out _);

    /// <summary>
    /// One intent record, or null when it is not this root's or does not verify,
    /// together with the exact map whose bytes were verified.
    /// </summary>
    /// <remarks>
    /// The verified map is handed back so that an amender can re-sign WHAT WAS
    /// PROVEN rather than whatever is at the path when it gets around to reading
    /// again. The signature is already removed from it, which is the same shape
    /// <see cref="WriteSigned"/> signs.
    /// </remarks>
    private StandingIntent? Read(string path, out MapNode? verified)
    {
        verified = null;
        JsonElement root;
        try
        {
            root = StrictJson.ReadObjectFile(path, Label, MaximumBytes);
        }
        catch (ContractException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            // Not an IOException in this runtime, and this method is reached from
            // a finally. An unreadable record is the unaccounted-for case, which
            // is what a null already means here.
            return null;
        }
        try
        {
            StrictJson.RequireLiteral(root, "contractVersion", ContractVersion, Label);
            StrictJson.RequireLiteral(root, "correlationId", _request.CorrelationId, Label);
            var signature = StrictJson.RequireObject(root, "signature", Label);
            var recorded = StrictJson.RequireHex(signature, "value", Label + " signature", 64);
            var map = (MapNode)Node.FromJson(root, Label);
            map.Remove("signature");
            var expected = CanonicalJson.HmacHex(_stateKey, CanonicalJson.Canonical(map));
            if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expected), Convert.FromHexString(recorded)))
            {
                return null;
            }
            verified = map;
            return new StandingIntent(
                StrictJson.RequireString(root, "step", Label),
                StrictJson.RequireInt(root, "attempt", Label, 1, int.MaxValue),
                StrictJson.RequireInt(root, "launchSequence", Label, 1, int.MaxValue),
                StrictJson.RequireString(root, "phase", Label),
                path,
                root.TryGetProperty("childProcessId", out var idNode) && idNode.ValueKind == JsonValueKind.Number && idNode.TryGetInt32(out var id) ? id : 0,
                root.TryGetProperty("childStartedAtUtc", out var startNode) && startNode.ValueKind == JsonValueKind.String
                    ? startNode.GetString() ?? string.Empty
                    : string.Empty);
        }
        catch (ContractException)
        {
            verified = null;
            return null;
        }
    }

    private MapNode Compose(
        string step,
        int attempt,
        long launchSequence,
        string childRequestSha256,
        string childSpecSha256,
        string requestPath,
        string expectedResultPath)
    {
        var current = Process.GetCurrentProcess();
        return new MapNode()
            .Set("contractVersion", ContractVersion)
            .Set("kind", "shadow-run-coordinator-launch-intent")
            .Set("correlationId", _request.CorrelationId)
            .Set("requestSha256", _request.RequestSha256)
            .Set("subjectSha256", CoordinatorState.SubjectDigest(_request))
            .Set("transition", Binding.Transition)
            .Set("setId", Binding.SetId)
            .Set("slotName", Binding.SlotName)
            .Set("step", step)
            .Set("attempt", attempt)
            .Set("launchSequence", launchSequence)
            .Set("childRequestPath", requestPath)
            .Set("childRequestSha256", childRequestSha256)
            .Set("childSpecSha256", childSpecSha256)
            .Set("expectedResultPath", expectedResultPath)
            .Set("expectedTerminalPath", Binding.ExpectedTerminalPath)
            // The lease this launch was made under, by the file that holds it and
            // by the process that holds the file. A launch whose lease record no
            // longer digests to this is a launch made by a coordinator that is not
            // the one holding the root now.
            .Set("leasePath", _request.LeasePath)
            .Set("leaseSha256", DigestOrNone(_request.LeasePath))
            .Set("leaseProcessId", current.Id)
            .Set("leaseProcessStartedAtUtc", LeaseProcessStart(current))
            .Set("intendedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture))
            .Set("phase", PhaseIntended)
            .Set("outcome", string.Empty)
            .Set("terminalReason", string.Empty);
    }

    private static string LeaseProcessStart(Process current)
    {
        try
        {
            return current.StartTime.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            return string.Empty;
        }
    }

    private static string DigestOrNone(string path)
    {
        try
        {
            return File.Exists(path) ? CanonicalJson.Sha256HexOfFile(path) : "none";
        }
        catch (IOException)
        {
            return "none";
        }
    }

    /// <summary>
    /// The next launch number for this output root, one past the highest any
    /// record holds. Derived from the records rather than from a counter this
    /// process keeps, so it keeps increasing across a restart.
    /// </summary>
    private long NextLaunchSequence()
    {
        long highest = 0;
        foreach (var record in ReadAll())
        {
            if (record.LaunchSequence > highest)
            {
                highest = record.LaunchSequence;
            }
        }
        return highest + 1;
    }

    private int NextAttempt(string step)
    {
        var standing = ReadStanding(step);
        return standing is null ? 1 : standing.Attempt + 1;
    }

    private string IntentPath(string step, int attempt) =>
        Path.Combine(_request.LaunchIntentRoot, $"{Stem(step)}-{attempt.ToString("D4", CultureInfo.InvariantCulture)}.intent.json");

    private string Stem(string step) => _request.CorrelationId + "-" + step;

    /// <summary>
    /// Keeps a diagnostic message a diagnostic message. A child's refusal can be
    /// long, and an intent record is read on the path that decides whether a root
    /// is resumable; it must not become a place arbitrary text is stored.
    /// </summary>
    private static string Truncate(string reason) =>
        reason.Length <= 512 ? reason : reason[..512];
}
