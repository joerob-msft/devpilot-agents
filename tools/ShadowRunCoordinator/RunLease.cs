using System.Diagnostics;
using System.Globalization;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Thrown when another live coordinator already holds this output root.
/// </summary>
internal sealed class LeaseConflictException(string message) : Exception(message);

/// <summary>
/// One coordinator per output root, decided from files rather than from a
/// process list.
/// </summary>
/// <remarks>
/// The hard part of a lease is not taking it, it is deciding whether a lease
/// left behind by a killed process is still live. Two mistakes are available and
/// this takes neither. Trusting the recorded identifier alone would hand the
/// root to nobody forever after a kill, because the operating system reuses
/// identifiers and some unrelated process now answers to that number. Matching on
/// what a process looks like - its command text - would be worse, because command
/// text is attacker-controlled, locale-dependent and unavailable for processes
/// this user cannot open.
///
/// So the lease records the identifier AND the exact process start time, and a
/// holder counts as live only when both agree. A reused identifier belongs to a
/// process that started later than the record says, so it fails the second half
/// and the lease is correctly treated as abandoned.
/// </remarks>
internal sealed class RunLease : IDisposable
{
    private const string ContractVersionValue = "devpilot.shadow-run-coordinator.lease.v1";

    private readonly string _path;
    private FileStream? _handle;
    private bool _released;

    private RunLease(string path, FileStream handle, bool tookOverAbandoned)
    {
        _path = path;
        _handle = handle;
        TookOverAbandoned = tookOverAbandoned;
    }

    /// <summary>True when this run adopted a lease whose holder was gone.</summary>
    internal bool TookOverAbandoned { get; }

    private static string LiveChildMessage(CoordinatorRequest request, string child) =>
        $"The output root '{request.OutputRoot}' still has {child}. " +
        "A coordinator that was killed leaves its child running; this run does not write alongside it. " +
        "Wait for that child to exit, or end it, and run again.";

    internal static RunLease Acquire(CoordinatorRequest request)
    {        Directory.CreateDirectory(request.CoordinatorRoot);
        var tookOver = false;

        // The one child a live-child conflict must NOT refuse: the supervised slot
        // this root's own signed record says it left running. A coordinator killed
        // during an hour-long slot leaves exactly that, and the whole point of
        // committing the child's identity before waiting on it is that the next run
        // can adopt it. Read from the signed record rather than from the journal, so
        // a planted journal cannot claim the exemption, and read-only, so this
        // decision writes nothing and mints no key.
        var adoptable = CoordinatorState.TryReadRecordedSlotChild(request);

        // A dead coordinator's lease can be taken over; a dead coordinator's CHILD
        // cannot be reasoned away. When a coordinator is killed from outside it
        // never runs its own cleanup, so the pwsh process it started keeps writing
        // this output root. Taking the lease over the top of that child would put
        // two writers in one root, which is the single thing the lease exists to
        // prevent - so a recorded child that is still alive is a conflict in its
        // own right, whatever the lease file says.
        if (DescribeConflictingChild(request, adoptable) is { } liveChild)
        {
            throw new LeaseConflictException(LiveChildMessage(request, liveChild));
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                // CreateNew is the whole race: two coordinators reaching this line
                // together cannot both succeed, and the loser never looks at the
                // holder record to decide, so it cannot talk itself into taking over.
                var handle = new FileStream(request.LeasePath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
                try
                {
                    var current = Process.GetCurrentProcess();
                    var record = new MapNode()
                        .Set("contractVersion", ContractVersionValue)
                        .Set("correlationId", request.CorrelationId)
                        .Set("processId", current.Id)
                        .Set("processStartedAtUtc", current.StartTime.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture))
                        .Set("acquiredAtUtc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
                    var bytes = StrictJson.StrictUtf8.GetBytes(CanonicalJson.Readable(record));
                    handle.Write(bytes, 0, bytes.Length);
                    handle.Flush(flushToDisk: true);
                    // Re-read the journals while the lease is HELD. The check above
                    // is only an early, friendlier refusal: on its own it races a
                    // coordinator that starts a child and is killed in the window
                    // between that check and this acquisition, which would leave
                    // this run holding the lease beside a live writer. Deciding it
                    // again from inside the lease is what actually settles it,
                    // because no third coordinator can be launching a child here.
                    if (DescribeConflictingChild(request, adoptable) is { } racedChild)
                    {
                        throw new LeaseConflictException(LiveChildMessage(request, racedChild));
                    }
                }
                catch (LeaseConflictException)
                {
                    // Give the lease back before reporting: a conflict this run did
                    // not cause must not leave a lease file behind that outlives it.
                    handle.Dispose();
                    File.Delete(request.LeasePath);
                    throw;
                }
                catch
                {
                    handle.Dispose();
                    File.Delete(request.LeasePath);
                    throw;
                }
                return new RunLease(request.LeasePath, handle, tookOver);
            }
            catch (IOException) when (File.Exists(request.LeasePath))
            {
                var holder = ReadHolder(request.LeasePath);
                if (holder is not null && IsHolderLive(holder.Value.ProcessId, holder.Value.StartedAtUtc))
                {
                    throw new LeaseConflictException(
                        $"Process {holder.Value.ProcessId.ToString(CultureInfo.InvariantCulture)} already holds the coordinator lease at '{request.LeasePath}'.");
                }
                if (holder is null && IsWithinPublishGrace(request.LeasePath))
                {
                    // The file exists but carries no readable holder record, and it
                    // was created moments ago. That is overwhelmingly the winner of
                    // the CreateNew race in the instant between creating the lease
                    // and flushing its record, not an abandoned one. Stealing it
                    // here would be fatal on a platform whose unlink succeeds
                    // against an open handle: both coordinators would then believe
                    // they held the same output root, which is the single outcome
                    // this lease exists to prevent.
                    throw new LeaseConflictException(
                        $"The coordinator lease at '{request.LeasePath}' was created within the last {PublishGraceSeconds.ToString(CultureInfo.InvariantCulture)} second(s) and has not published its holder record yet; it is treated as live rather than stolen.");
                }
                // The holder is gone, so the lease is evidence of a kill rather
                // than of a live run. Remove it and try once more; if that second
                // attempt loses the CreateNew race to somebody else, the loop ends
                // and the conflict is reported rather than forced.
                tookOver = true;
                try
                {
                    File.Delete(request.LeasePath);
                }
                catch (IOException)
                {
                    throw new LeaseConflictException($"The coordinator lease at '{request.LeasePath}' is held open by another process.");
                }
                catch (UnauthorizedAccessException)
                {
                    throw new LeaseConflictException($"The coordinator lease at '{request.LeasePath}' cannot be removed by this user.");
                }
            }
        }

        throw new LeaseConflictException($"The coordinator lease at '{request.LeasePath}' was taken by another process.");
    }

    private const int PublishGraceSeconds = 30;

    /// <summary>
    /// Describes a live recorded child that this run may not write alongside, or
    /// null when every live recorded child is the slot this root's signed record
    /// entitles the run to adopt.
    /// </summary>
    /// <remarks>
    /// The exemption is exact: the same process id AND the same recorded start
    /// time as the committed record. A recycled id fails the second half and is
    /// therefore still a conflict, which is the safe direction to be wrong in.
    /// </remarks>
    private static string? DescribeConflictingChild(
        CoordinatorRequest request,
        (int ProcessId, string StartedAtUtc)? adoptable)
    {
        foreach (var recorded in ChildJournal.EnumerateRecordedChildren(request))
        {
            if (adoptable is { } owned
                && recorded.ProcessId == owned.ProcessId
                && string.Equals(recorded.StartedAtUtc, owned.StartedAtUtc, StringComparison.Ordinal))
            {
                continue;
            }
            if (ChildJournal.IsAlive(recorded))
            {
                return ChildJournal.Describe(recorded);
            }
        }
        return null;
    }

    /// <summary>
    /// True when the lease file was created so recently that a holder record it
    /// has not published yet is better explained by an in-flight acquisition than
    /// by an abandoned one.
    /// </summary>
    private static bool IsWithinPublishGrace(string path)
    {
        try
        {
            var info = new FileInfo(path);
            // Creation time is not recorded on every file system, so the newer of
            // the two stamps is used; a just-created empty file is 'now' by either.
            var stamped = info.CreationTimeUtc > info.LastWriteTimeUtc ? info.CreationTimeUtc : info.LastWriteTimeUtc;
            var age = DateTime.UtcNow - stamped;
            return age >= TimeSpan.Zero && age < TimeSpan.FromSeconds(PublishGraceSeconds);
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static (int ProcessId, DateTime StartedAtUtc)? ReadHolder(string path)    {
        try
        {
            const string label = "coordinator lease";
            var root = StrictJson.ReadObjectFile(path, label, maximumBytes: 64 * 1024);
            var processId = StrictJson.RequireInt(root, "processId", label, 1, int.MaxValue);
            var startedText = StrictJson.RequireString(root, "processStartedAtUtc", label);
            // RoundtripKind alone: it already honours the offset the writer emitted,
            // and combining it with a conversion style is rejected outright. Getting
            // this wrong once turned an abandoned lease into an unhandled crash
            // rather than into the takeover it should have been.
            if (!DateTime.TryParse(
                    startedText,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var started))
            {
                return null;
            }
            return (processId, started.ToUniversalTime());
        }
        catch (ContractException)
        {
            // An unreadable lease is a lease no live holder wrote completely. It
            // is treated as abandoned rather than as a conflict, because refusing
            // forever on a corrupt byte would make a single bad write permanent.
            return null;
        }
        catch (FormatException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static bool IsHolderLive(int processId, DateTime startedAtUtc)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            if (process.HasExited)
            {
                return false;
            }
            var actual = process.StartTime.ToUniversalTime();
            // A whole second of tolerance, because the recorded value round-trips
            // through text. Identifier reuse takes far longer than that in
            // practice, so this stays a discriminating test.
            return Math.Abs((actual - startedAtUtc).TotalSeconds) < 1.0;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        // A holder this user cannot inspect is deliberately NOT treated as dead:
        // stealing a lease from a process we cannot see is the one direction where
        // being wrong runs two coordinators at once.
        catch (System.ComponentModel.Win32Exception)
        {
            return true;
        }
    }

    public void Dispose()
    {
        if (_released)
        {
            return;
        }
        _released = true;
        _handle?.Dispose();
        _handle = null;
        try
        {
            File.Delete(_path);
        }
        catch (IOException)
        {
            // A lease left behind is recoverable on the next run by exactly the
            // takeover path above; failing the run over it would be worse.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
