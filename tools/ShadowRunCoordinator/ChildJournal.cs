using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>A child this output root's journals record, with the identity that makes it findable.</summary>
internal sealed record RecordedChild(string Step, int ProcessId, string StartedAtUtc, string JournalPath);

/// <summary>
/// The launch journal every child of this output root is recorded in.
/// </summary>
/// <remarks>
/// One implementation on purpose. Two things start children now - the short
/// synchronous invoker and the slot supervisor - and they must agree exactly on
/// what a live writer of an output root looks like, or a resume would clear a
/// root one of them still considers occupied. Identity is the process id AND its
/// start time together, because process ids are recycled and an id alone would
/// let an unrelated process masquerade as a live writer.
///
/// A journal is a diagnostic aid for a resume, never a gate on its own: an
/// unreadable entry is skipped rather than allowed to wedge a root, and liveness
/// is always re-derived from the live process table rather than believed from a
/// file.
/// </remarks>
internal static class ChildJournal
{
    internal const string ContractVersion = "devpilot.shadow-run-coordinator.child-journal.v1";

    private const string Label = "child step journal";

    private const int MaximumBytes = 64 * 1024;

    /// <summary>
    /// Writes the launch journal for one step. When a process is supplied the
    /// entry additionally records that exact child, which is what lets a later
    /// run refuse to write an output root a previous coordinator's child is still
    /// writing.
    /// </summary>
    internal static void Write(
        string journalPath,
        string correlationId,
        string step,
        string childRequestSha256,
        int attempt,
        Process? process)
    {
        var entry = new MapNode()
            .Set("contractVersion", ContractVersion)
            .Set("correlationId", correlationId)
            .Set("step", step)
            .Set("childRequestSha256", childRequestSha256)
            .Set("attempt", attempt)
            .Set("launchedAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        if (process is not null)
        {
            entry.Set("childProcessId", process.Id);
            entry.Set("childStartedAtUtc", StartedAtUtc(process));
        }
        CanonicalJson.WriteFileAtomic(journalPath, CanonicalJson.Readable(entry));
    }

    /// <summary>
    /// The attempt count already journalled for this exact step and child request,
    /// or zero when there is no usable journal entry.
    /// </summary>
    internal static int ReadAttempt(string journalPath, string correlationId, string step, string childRequestSha256)
    {
        if (!File.Exists(journalPath))
        {
            return 0;
        }
        try
        {
            var root = StrictJson.ReadObjectFile(journalPath, Label, MaximumBytes);
            StrictJson.RequireLiteral(root, "contractVersion", ContractVersion, Label);
            if (!string.Equals(StrictJson.RequireString(root, "step", Label), step, StringComparison.Ordinal)
                || !string.Equals(StrictJson.RequireString(root, "correlationId", Label), correlationId, StringComparison.Ordinal)
                || !string.Equals(StrictJson.RequireString(root, "childRequestSha256", Label), childRequestSha256, StringComparison.Ordinal))
            {
                return 0;
            }
            return StrictJson.RequireInt(root, "attempt", Label, 1, int.MaxValue);
        }
        catch (ContractException)
        {
            return 0;
        }
    }

    internal static void TryClearChild(string journalPath, string correlationId, string step, string childRequestSha256, int attempt)
    {
        try
        {
            Write(journalPath, correlationId, step, childRequestSha256, attempt, null);
        }
        catch (IOException)
        {
            // Failing to clear a diagnostic aid must not turn a successful step
            // into a failed one; the liveness reader checks the recorded process
            // itself rather than trusting the entry.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    internal static string StartedAtUtc(Process process)
    {
        try
        {
            return process.StartTime.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            return string.Empty;
        }
    }

    /// <summary>The child one journal file records, or null when it records none this run can find.</summary>
    internal static RecordedChild? ReadRecordedChild(string journalPath)
    {
        JsonElement root;
        try
        {
            root = StrictJson.ReadObjectFile(journalPath, Label, MaximumBytes);
        }
        catch (ContractException)
        {
            return null;
        }
        if (!root.TryGetProperty("childProcessId", out var idNode) || idNode.ValueKind != JsonValueKind.Number
            || !root.TryGetProperty("childStartedAtUtc", out var startedNode) || startedNode.ValueKind != JsonValueKind.String)
        {
            return null;
        }
        var recordedStart = startedNode.GetString() ?? string.Empty;
        if (recordedStart.Length == 0 || !idNode.TryGetInt32(out var recordedId))
        {
            return null;
        }
        var step = root.TryGetProperty("step", out var stepNode) && stepNode.ValueKind == JsonValueKind.String
            ? stepNode.GetString() ?? "unknown"
            : "unknown";
        return new RecordedChild(step, recordedId, recordedStart, journalPath);
    }

    /// <summary>
    /// True when the exact recorded child is still running. A matching id whose
    /// start time differs is a recycled id and is deliberately not the child.
    /// </summary>
    internal static bool IsAlive(RecordedChild child)
    {
        Process candidate;
        try
        {
            candidate = Process.GetProcessById(child.ProcessId);
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
            return IsSameProcess(candidate, child.StartedAtUtc);
        }
    }

    /// <summary>
    /// True only when a live process is provably the one a start time recorded.
    /// An unreadable start time is empty on both sides, so a plain comparison
    /// would call any process whose start time this account cannot read the
    /// child, and a recycled id would then be waited on and killed. Identity
    /// this weak is no identity, so the unknown case is not a match.
    /// </summary>
    internal static bool IsSameProcess(Process candidate, string recordedStartedAtUtc)
    {
        if (recordedStartedAtUtc.Length == 0)
        {
            return false;
        }
        var observed = StartedAtUtc(candidate);
        return observed.Length != 0 && string.Equals(observed, recordedStartedAtUtc, StringComparison.Ordinal);
    }

    /// <summary>
    /// Describes one recorded child, for a refusal a person has to act on.
    /// </summary>
    internal static string Describe(RecordedChild child) =>
        $"a '{child.Step}' child (process {child.ProcessId.ToString(CultureInfo.InvariantCulture)}, started {child.StartedAtUtc}) recorded in '{Path.GetFileName(child.JournalPath)}'";

    internal static RecordedChild? FindLiveRecordedChild(CoordinatorRequest request)
    {
        foreach (var recorded in EnumerateRecordedChildren(request))
        {
            if (IsAlive(recorded))
            {
                return recorded;
            }
        }
        return null;
    }

    internal static IEnumerable<RecordedChild> EnumerateRecordedChildren(CoordinatorRequest request)
    {
        if (!Directory.Exists(request.ExchangeRoot))
        {
            yield break;
        }
        foreach (var journalPath in Directory.EnumerateFiles(request.ExchangeRoot, "*.journal.json", SearchOption.TopDirectoryOnly))
        {
            var recorded = ReadRecordedChild(journalPath);
            if (recorded is not null)
            {
                yield return recorded;
            }
        }
    }

    /// <summary>Kills a process and everything it started, and waits a bounded time for the tree to go.</summary>
    internal static void KillTree(Process process, int drainMilliseconds)
    {
        try
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit(drainMilliseconds);
        }
        catch (InvalidOperationException)
        {
        }
        // Killing a tree is best effort by construction: the runtime reports a
        // descendant it could not terminate - including one that was already
        // terminating on its own, the ordinary race under a deep reviewer tree -
        // as an AggregateException of Win32Exceptions. Letting that escape would
        // abort the caller's cleanup and leave the journal naming a live child
        // forever. Whether the tree actually went is decided by the bounded wait
        // and by the artifact the child did or did not write, never by this call
        // returning quietly.
        catch (AggregateException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
        catch (NotSupportedException)
        {
        }
    }
}
