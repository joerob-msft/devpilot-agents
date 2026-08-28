using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// A minimal JSON tree the coordinator builds for its own records.
/// </summary>
/// <remarks>
/// Deliberately its own tiny type rather than a reuse of the seal formats. There
/// is exactly one normative canonicalizer in this system and it is the PowerShell
/// production implementation; nothing here may mint a production seal. What this
/// writes is the coordinator's own versioned state and audit, which no other
/// component reads, so it carries its own namespace and its own canonical form.
/// </remarks>
internal abstract class Node
{
    internal static Node Text(string value) => new TextNode(value);

    internal static Node Number(long value) => new NumberNode(value);

    internal static Node Flag(bool value) => new FlagNode(value);

    internal static Node Null() => NullNode.Instance;

    /// <summary>
    /// Rebuilds a node from JSON the coordinator itself wrote.
    /// </summary>
    /// <remarks>
    /// Bounded and total: depth is capped, and every value kind is either
    /// converted or refused by name. It exists so a resumed run can restore the
    /// evidence it recorded before it was killed, rather than reporting a
    /// thinner audit than an uninterrupted run would have produced.
    ///
    /// Numbers are restored as integers only. The coordinator records counts,
    /// lengths and sequences and never a fraction, so a fractional number here
    /// means the file is not one this coordinator wrote.
    /// </remarks>
    internal static Node FromJson(JsonElement element, string label, int depth = 0)
    {
        if (depth > 32)
        {
            throw new ContractException($"The {label} nests more than 32 levels deep.");
        }
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var map = new MapNode();
                foreach (var property in element.EnumerateObject())
                {
                    map.Set(property.Name, FromJson(property.Value, label, depth + 1));
                }
                return map;
            case JsonValueKind.Array:
                var list = new ListNode();
                foreach (var item in element.EnumerateArray())
                {
                    list.Add(FromJson(item, label, depth + 1));
                }
                return list;
            case JsonValueKind.String:
                return Text(element.GetString() ?? throw new ContractException($"The {label} holds a null string."));
            case JsonValueKind.Number:
                if (!element.TryGetInt64(out var number))
                {
                    throw new ContractException($"The {label} holds the non-integer number {element.GetRawText()}.");
                }
                return Number(number);
            case JsonValueKind.True:
                return Flag(true);
            case JsonValueKind.False:
                return Flag(false);
            case JsonValueKind.Null:
                return Null();
            default:
                throw new ContractException($"The {label} holds a {StrictJson.Describe(element.ValueKind)} that cannot be restored.");
        }
    }

    internal abstract void Write(StringBuilder builder, bool canonical, int indent);

    /// <summary>The string this node carries, or null when it is not a string.</summary>
    internal virtual string? AsText => null;

    /// <summary>The integer this node carries, or null when it is not a number.</summary>
    internal virtual long? AsInteger => null;

    /// <summary>The boolean this node carries, or null when it is not a boolean.</summary>
    internal virtual bool? AsFlag => null;

    private sealed class TextNode(string value) : Node
    {
        internal override string? AsText => value;

        internal override void Write(StringBuilder builder, bool canonical, int indent) =>
            CanonicalJson.WriteString(value, builder);
    }

    private sealed class NumberNode(long value) : Node
    {
        internal override long? AsInteger => value;

        internal override void Write(StringBuilder builder, bool canonical, int indent) =>
            builder.Append(value.ToString(CultureInfo.InvariantCulture));
    }

    private sealed class FlagNode(bool value) : Node
    {
        internal override bool? AsFlag => value;

        internal override void Write(StringBuilder builder, bool canonical, int indent) =>
            builder.Append(value ? "true" : "false");
    }

    private sealed class NullNode : Node
    {
        internal static readonly NullNode Instance = new();

        internal override void Write(StringBuilder builder, bool canonical, int indent) =>
            builder.Append("null");
    }
}

/// <summary>An ordered map. Insertion order is kept for the readable form and sorted for the canonical one.</summary>
internal sealed class MapNode : Node
{
    private readonly List<KeyValuePair<string, Node>> _entries = [];

    internal MapNode Set(string name, Node value)
    {
        for (var index = 0; index < _entries.Count; index++)
        {
            if (string.Equals(_entries[index].Key, name, StringComparison.Ordinal))
            {
                _entries[index] = new KeyValuePair<string, Node>(name, value);
                return this;
            }
        }
        _entries.Add(new KeyValuePair<string, Node>(name, value));
        return this;
    }

    internal MapNode Set(string name, string value) => Set(name, Text(value));

    internal MapNode Set(string name, long value) => Set(name, Number(value));

    internal MapNode Set(string name, bool value) => Set(name, Flag(value));

    internal void Remove(string name) => _entries.RemoveAll(entry => string.Equals(entry.Key, name, StringComparison.Ordinal));

    /// <summary>The node stored under a name, or null when there is none.</summary>
    internal Node? Get(string name)
    {
        foreach (var entry in _entries)
        {
            if (string.Equals(entry.Key, name, StringComparison.Ordinal))
            {
                return entry.Value;
            }
        }
        return null;
    }

    /// <summary>The string stored under a name, or null when it is absent or not a string.</summary>
    internal string? GetText(string name) => Get(name)?.AsText;

    /// <summary>The integer stored under a name, or null when it is absent or not a number.</summary>
    internal long? GetInteger(string name) => Get(name)?.AsInteger;

    /// <summary>The boolean stored under a name, or null when it is absent or not a boolean.</summary>
    internal bool? GetFlag(string name) => Get(name)?.AsFlag;

    internal override void Write(StringBuilder builder, bool canonical, int indent)
    {
        var entries = canonical
            ? _entries.OrderBy(entry => entry.Key, StringComparer.Ordinal).ToList()
            : _entries;
        builder.Append('{');
        for (var index = 0; index < entries.Count; index++)
        {
            if (index != 0)
            {
                builder.Append(',');
            }
            CanonicalJson.Break(builder, canonical, indent + 1);
            CanonicalJson.WriteString(entries[index].Key, builder);
            builder.Append(':');
            if (!canonical)
            {
                builder.Append(' ');
            }
            entries[index].Value.Write(builder, canonical, indent + 1);
        }
        if (entries.Count > 0)
        {
            CanonicalJson.Break(builder, canonical, indent);
        }
        builder.Append('}');
    }
}

/// <summary>A list. Order is meaning here, so the canonical form never sorts it.</summary>
internal sealed class ListNode : Node
{
    private readonly List<Node> _items = [];

    internal int Count => _items.Count;

    /// <summary>The items, in the order they were added.</summary>
    internal IReadOnlyList<Node> Items => _items;

    internal ListNode Add(Node item)
    {
        _items.Add(item);
        return this;
    }

    internal ListNode Add(string item) => Add(Text(item));

    internal override void Write(StringBuilder builder, bool canonical, int indent)
    {
        builder.Append('[');
        for (var index = 0; index < _items.Count; index++)
        {
            if (index != 0)
            {
                builder.Append(',');
            }
            CanonicalJson.Break(builder, canonical, indent + 1);
            _items[index].Write(builder, canonical, indent + 1);
        }
        if (_items.Count > 0)
        {
            CanonicalJson.Break(builder, canonical, indent);
        }
        builder.Append(']');
    }
}

internal static class CanonicalJson
{
    /// <summary>
    /// The bytes a coordinator record is signed over: keys sorted, no
    /// whitespace, every control character escaped. This is the coordinator's own
    /// canonical form for its own records, not any seal format.
    /// </summary>
    internal static string Canonical(Node node)
    {
        var builder = new StringBuilder();
        node.Write(builder, canonical: true, indent: 0);
        return builder.ToString();
    }

    /// <summary>The same content laid out for a human, with one trailing newline.</summary>
    internal static string Readable(Node node)
    {
        var builder = new StringBuilder();
        node.Write(builder, canonical: false, indent: 0);
        builder.Append('\n');
        return builder.ToString();
    }

    internal static void Break(StringBuilder builder, bool canonical, int indent)
    {
        if (canonical)
        {
            return;
        }
        builder.Append('\n');
        builder.Append(' ', indent * 2);
    }

    internal static void WriteString(string value, StringBuilder builder)
    {
        builder.Append('"');
        foreach (var character in value)
        {
            switch (character)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (character < 32 || character == 127)
                    {
                        builder.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        builder.Append(character);
                    }
                    break;
            }
        }
        builder.Append('"');
    }

    internal static string Sha256Hex(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    internal static string Sha256HexOfText(string text) =>
        Sha256Hex(StrictJson.StrictUtf8.GetBytes(text));

    internal static string Sha256HexOfFile(string path)
    {
        // FileShare.Delete is the load-bearing flag, not politeness. Without it a
        // reader that merely wants a digest takes a Windows lock that blocks the
        // replace half of WriteFileAtomic, which is how a routine verification
        // read used to wedge a state publish. Delete-sharing lets the publisher
        // swap the name underneath us; this handle keeps reading the bytes it
        // opened, which is exactly the snapshot semantics a digest wants.
        using var stream = OpenPublishedFileForRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    // The reader recovery window. The ReplaceFile fallback in PublishOnce renames
    // the destination aside to a named backup and moves the replacement in, so for
    // one instant the path does not resolve while a '<name>.<guid>.bak' sibling
    // holds the old content. A reader arriving precisely then would see a state
    // file that "does not exist" even though the publish is old-or-new by
    // contract. This bound gives that PROVEN-TRANSIENT window - and only that
    // window - time to close. It is the same shape and budget as the publish's own
    // retry, a little over a second in total.
    private const int ReaderRecoveryMaxAttempts = 11;
    private const int ReaderRecoveryInitialBackoffMilliseconds = 2;
    private const int ReaderRecoveryMaxBackoffMilliseconds = 512;

    /// <summary>
    /// Opens a state file for a shared, snapshot read, recovering ONLY across the
    /// transient absence a ReplaceFile-fallback publish exposes and failing fast on
    /// genuine absence.
    /// </summary>
    /// <remarks>
    /// The recovery is gated on a signal that a publish - not a deletion - is the
    /// reason the path is momentarily gone: the named backup the fallback creates,
    /// '&lt;name&gt;.&lt;guid&gt;.bak', sitting beside the destination. While such a
    /// sibling exists the absence is treated as a publish in flight and waited out
    /// within a bounded budget; with no such sibling the absence is real and the
    /// FileNotFoundException is allowed to travel on the first try, so a genuinely
    /// missing state file still fails fast rather than being retried into a delay.
    /// </remarks>
    internal static FileStream OpenPublishedFileForRead(string path)
    {
        var backoff = ReaderRecoveryInitialBackoffMilliseconds;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
            }
            catch (Exception transient) when (
                attempt < ReaderRecoveryMaxAttempts && IsReaderRecoverable(path, transient))
            {
                // A publish is swapping the destination underneath us: the path is
                // momentarily renamed aside, or briefly held while the replace
                // primitive moves it. Give the swap the rest of its window and look
                // again. A genuine absence or a real lock is NOT recoverable here
                // and travels on the first look.
                Thread.Sleep(backoff);
                backoff = Math.Min(backoff * 2, ReaderRecoveryMaxBackoffMilliseconds);
            }
        }
    }

    /// <summary>
    /// Whether a failed open of a published file is a transient of a publish in
    /// flight - and therefore worth a bounded retry - rather than a genuine fault.
    /// </summary>
    /// <remarks>
    /// Two transients, kept apart on purpose. An ABSENCE is only recoverable when
    /// a fallback publish accounts for it - its named backup sitting beside the
    /// target, or the target being back already - so a path that is simply not
    /// there, with no publish to explain it, still fails fast. A brief SHARING
    /// VIOLATION is the destination being held for the instant the replace moves
    /// it; it means the file exists and is locked, never that it is missing, so
    /// it is bounded-retried on the same terms the writer tolerates it and cannot
    /// mask a real deletion.
    /// </remarks>
    private static bool IsReaderRecoverable(string path, Exception exception)
    {
        if (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return PublishInFlight(path);
        }
        return IsTransientSharingViolation(exception, path);
    }

    /// <summary>
    /// Whether a ReplaceFile-fallback publish of this path is in flight - or has
    /// just finished - judged by facts on disk rather than by timing.
    /// </summary>
    /// <remarks>
    /// Two signals, and the second is not redundant. The first is the named
    /// backup the fallback creates beside the target: a publish is mid-swap. The
    /// second is the destination being there again by the time the question is
    /// asked, which is proof AFTER THE FACT that the absence was the swap window
    /// and not a deletion - a retry will now succeed.
    ///
    /// Asking only the first is a race, and a hosted runner lost it: the publish
    /// completed and its backup was deleted between the reader's failed open and
    /// the reader's look, so an absence that had already ended was reported as a
    /// genuine missing file. Neither signal fires for a path that is simply not
    /// there, so a real deletion still travels on the first look.
    /// </remarks>
    internal static bool PublishInFlight(string path)
    {
        // Cheapest and most decisive: the file is back, so whatever the absence
        // was, it is over and the next open resolves it.
        if (File.Exists(path))
        {
            return true;
        }
        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full);
        if (string.IsNullOrEmpty(directory))
        {
            return false;
        }
        try
        {
            // The backup is named '<destination file name>.<guid>.bak' in
            // PublishOnce. Match that exact shape rather than any .bak, so an
            // unrelated file that happens to end in .bak never turns a genuine
            // absence into a retried one.
            using var matches = Directory
                .EnumerateFiles(directory, Path.GetFileName(full) + ".*.bak")
                .GetEnumerator();
            return matches.MoveNext();
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or DirectoryNotFoundException)
        {
            return false;
        }
    }

    internal static string HmacHex(byte[] key, string text) =>
        Convert.ToHexString(HMACSHA256.HashData(key, StrictJson.StrictUtf8.GetBytes(text))).ToLowerInvariant();

    /// <summary>
    /// Raised when an atomic publish exhausted its retry budget against a
    /// transient Windows sharing violation. Recoverable on purpose: the
    /// destination still holds exactly the old content or exactly the new one,
    /// so a resumed run may simply try again. Removal of the temporary is
    /// attempted but not promised - a foreign handle can hold that file too, and
    /// failing the publish over a cleanup would be the worse trade.
    /// </summary>
    internal sealed class AtomicPublishTimeoutException : Exception
    {
        internal AtomicPublishTimeoutException(string path, int attempts, int elapsedMilliseconds, Exception inner)
            : base($"Publishing '{path}' did not complete within {attempts} attempt(s) over {elapsedMilliseconds}ms " +
                   "because the destination stayed locked by another process. The destination was left holding whole " +
                   "content; this is recoverable and may be retried.", inner)
        {
            Path = path;
            Attempts = attempts;
            ElapsedMilliseconds = elapsedMilliseconds;
        }

        internal string Path { get; }

        internal int Attempts { get; }

        internal int ElapsedMilliseconds { get; }

        /// <summary>Always true; named so a caller does not have to know the type.</summary>
        internal bool Recoverable => true;
    }

    // Windows returns these when the destination is momentarily held by someone
    // else. Recognised BY CODE rather than by message, and enumerated rather
    // than treated as "any IOException", because retrying a genuine failure - a
    // full disk, a bad path, a permission the process will never have - would
    // turn a fast, honest error into a slow one and still fail.
    private const int ErrorAccessDenied = 5;
    private const int ErrorSharingViolation = 32;
    private const int ErrorLockViolation = 33;

    // ReplaceFile's own two partial outcomes. 1176 leaves the destination under
    // its original name; 1177 leaves it under the backup name this code chooses,
    // which means the destination is momentarily ABSENT. Both are retryable, and
    // an earlier attempt recovers the 1177 case on its own: with the destination
    // gone the next attempt falls through to the rename, which puts the new
    // content there. On the LAST attempt there is no next one, so the publish
    // path restores the invariant explicitly instead - see PublishOnce's catch,
    // which puts the backup back, and PublishWithBoundedRetry's final check,
    // which will not report "unchanged" over a path that does not resolve. What
    // must never happen is treating either code as success.
    private const int ErrorUnableToMoveReplacement = 1176;
    private const int ErrorUnableToMoveReplacement2 = 1177;

    private static bool IsTransientSharingViolation(Exception exception, string path)
    {
        // ERROR_ACCESS_DENIED reaches us as UnauthorizedAccessException, and only
        // from the rename fallback - the path taken when the destination did not
        // exist. If it exists now, somebody raced us into creating and holding
        // it, which is transient. If it still does not, this is a real permission
        // problem and must fail immediately: retrying it would spend the budget
        // and then report a lock that was never the cause.
        if (exception is UnauthorizedAccessException)
        {
            return File.Exists(path);
        }
        if (exception is not IOException)
        {
            return false;
        }
        var code = exception.HResult & 0xFFFF;
        return code is ErrorSharingViolation or ErrorLockViolation or ErrorAccessDenied
            or ErrorUnableToMoveReplacement or ErrorUnableToMoveReplacement2;
    }

    /// <summary>
    /// Replace-in-place through a temporary file in the destination directory, so
    /// a reader never observes a half-written record. The temporary is a sibling
    /// because both of the replace primitives used below require the two paths to
    /// share a volume, and a cross-directory move would not give replace
    /// semantics at all.
    ///
    /// The replace prefers a rename (atomic, no instant at which the destination
    /// is missing) and falls back to Win32 ReplaceFile only when the destination
    /// is being held - because on Windows a rename over an open destination
    /// CANNOT succeed: MoveFileEx with MOVEFILE_REPLACE_EXISTING fails with
    /// ERROR_ACCESS_DENIED whenever anyone holds it, no matter what sharing that
    /// reader granted. ReplaceFile does succeed, provided the reader granted
    /// FILE_SHARE_DELETE - which is why every reader in this tool now does. The
    /// two changes are one fix; neither works alone.
    ///
    /// That combination is what makes the wedge impossible. Before it, an
    /// ordinary concurrent read - a digest check, a state read, a virus scanner -
    /// made the publish throw from its middle. Because the cohort journal records
    /// the intent to launch BEFORE the state describing it is published, the run
    /// was left with a journal asserting a launch and a state file that never
    /// agreed, and a resume could neither continue nor honestly abandon.
    ///
    /// The bounded retry below covers what remains: a reader that granted no
    /// delete sharing at all, which this tool no longer creates but other
    /// processes on the machine certainly do. It never weakens atomicity. Each
    /// attempt is the same single replace, so the destination holds the whole old
    /// content or the whole new content and never a blend. Only recognised
    /// sharing violations are retried; anything else is reported at once. The
    /// temporary is removed on every path out, including the timeout, on a best
    /// effort basis: the same foreign handle that can hold the destination can
    /// hold the temporary, and a cleanup that threw from the finally would
    /// REPLACE the typed publish result with a bare IOException, costing the
    /// caller the very Recoverable flag it is being handed. A leftover .tmp is
    /// the lesser harm and is what every other cleanup in this file already
    /// chooses.
    /// </summary>
    internal static void WriteFileAtomic(string path, string content)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (string.IsNullOrEmpty(directory))
        {
            throw new ContractException($"'{path}' must name a directory.");
        }
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        var bytes = StrictJson.StrictUtf8.GetBytes(content);
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(flushToDisk: true);
            }
            PublishWithBoundedRetry(temporary, path);
        }
        finally
        {
            try
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    // The budget: eleven attempts backing off 2,4,8,...,512ms, capped, for a
    // little over a second of tolerance in total. Long enough to outlast the
    // foreign scanner that causes this in practice, short enough that a
    // genuinely stuck destination is reported while the run still has somewhere
    // to report it.
    private const int AtomicPublishMaxAttempts = 11;
    private const int AtomicPublishInitialBackoffMilliseconds = 2;
    private const int AtomicPublishMaxBackoffMilliseconds = 512;

    /// <summary>
    /// Hook for fault injection. When set, it is consulted before every replace
    /// attempt and may throw to simulate a sharing violation. Tests need to
    /// exercise the retry deterministically; racing a real reader proves the
    /// integration but cannot prove the budget is ever exhausted.
    /// </summary>
    internal static Action<string, int>? AtomicPublishAttemptHook;

    /// <summary>Counters the self-test reads to prove which primitive did the work.</summary>
    internal static long AtomicPublishRenameCount;

    internal static long AtomicPublishReplaceCount;

    internal static long AtomicPublishPosixRenameCount;

    // One publish at a time per destination, within this process.
    //
    // ReplaceFile is not safe to race against itself: two concurrent replaces of
    // one destination can end with ERROR_UNABLE_TO_MOVE_REPLACEMENT_2, where the
    // destination has been renamed to the internal backup name and is, for a
    // moment, absent. Retrying recovers it, but a publish that briefly loses the
    // state file is not the guarantee this method advertises, and the honest fix
    // is not to create the race.
    //
    // In-process serialisation is sufficient BECAUSE a state file belongs to one
    // run and a run holds an exclusive lease (RunLease) for as long as it
    // publishes. Two processes publishing one path would already be a lease
    // violation, which is detected where leases are, not here.
    private static readonly Dictionary<string, object> PublishGates = new(StringComparer.OrdinalIgnoreCase);

    private static object GateFor(string path)
    {
        lock (PublishGates)
        {
            if (!PublishGates.TryGetValue(path, out var gate))
            {
                gate = new object();
                PublishGates[path] = gate;
            }
            return gate;
        }
    }

    // TEST ONLY. The POSIX rename succeeds on every NTFS volume this tool runs
    // on, which means the ReplaceFile fallback below - and the backup, restore
    // and cleanup logic that guards it - is never executed by a passing test on
    // a healthy host. That is precisely the code whose failure mode destroyed a
    // state file, so leaving it to be exercised only by the hosts that have no
    // POSIX rename is not acceptable. Setting this makes the self-test take the
    // fallback deliberately. It is never set by production code.
    internal static bool ForceReplaceFileFallbackForTests;

    private static void PublishOnce(string temporary, string path)
    {
        // A rename first, because it is the only genuinely atomic option: the
        // destination goes from whole old content to whole new content with no
        // instant in between at which it does not exist. In the ordinary case -
        // nobody reading - this is the whole story and the publish is perfect.
        try
        {
            if (ForceReplaceFileFallbackForTests && File.Exists(path))
            {
                throw new IOException("Forced onto the ReplaceFile fallback by a test.");
            }
            File.Move(temporary, path, overwrite: true);
            Interlocked.Increment(ref AtomicPublishRenameCount);
            return;
        }
        catch (Exception exception) when (
            (ForceReplaceFileFallbackForTests && exception is IOException && File.Exists(path)) ||
            IsTransientSharingViolation(exception, path))
        {
            // Somebody is holding the destination. A rename through MoveFileEx
            // can NEVER succeed against that on Windows, however long it is
            // retried, so retrying this call would spend the budget and then
            // wedge exactly as before.
        }

        // The kernel's POSIX rename does the same atomic swap and does tolerate
        // an open destination. This is the case the whole fix exists for, and it
        // keeps the guarantee intact: the path never stops resolving.
        if (!ForceReplaceFileFallbackForTests && NativeAtomicReplace.TryReplaceInPlace(temporary, path))
        {
            Interlocked.Increment(ref AtomicPublishPosixRenameCount);
            return;
        }

        // Last resort, for a host or filesystem with no POSIX rename. ReplaceFile
        // tolerates readers but works by renaming the destination aside and the
        // replacement into place, so for a brief instant the path does not
        // resolve. A reader arriving precisely then is turned away and can ask
        // again; that is a retry, not a torn read, and it is still far better
        // than a publish that fails outright and leaves the journal asserting a
        // launch whose state was never written.
        //
        // The aside copy is given a NAME WE CHOOSE rather than left to the
        // kernel's internal one. ERROR_UNABLE_TO_MOVE_REPLACEMENT_2 means the
        // destination was successfully renamed aside and the replacement then
        // failed to move in - so at that instant the destination does not exist,
        // and with an unnameable backup the old content would be unreachable
        // forever. Naming it makes that outcome recoverable: the old bytes go
        // back where they were, and the caller still sees old-or-new.
        var backup = path + "." + Guid.NewGuid().ToString("N") + ".bak";
        var backupIsTheOnlyCopy = false;
        try
        {
            File.Replace(temporary, path, destinationBackupFileName: backup, ignoreMetadataErrors: true);
            Interlocked.Increment(ref AtomicPublishReplaceCount);
        }
        catch (FileNotFoundException)
        {
            // The destination went away between the two calls. Nothing to
            // replace, so the atomic rename is available again.
            File.Move(temporary, path, overwrite: true);
            Interlocked.Increment(ref AtomicPublishRenameCount);
        }
        catch (Exception replaceFailure)
        {
            // Whatever the failure was, the invariant is restored before it is
            // reported: if the destination is gone and the old content is
            // sitting in the backup, put it back. Restoring first and rethrowing
            // second means no caller ever observes a missing state file.
            if (File.Exists(path) || !File.Exists(backup))
            {
                throw;
            }
            try
            {
                File.Move(backup, path, overwrite: false);
            }
            catch (Exception restoreFailure)
            {
                // The old content exists but could not be put back, and the new
                // content is about to be discarded with the temporary. Say so in
                // the one type that means "neither old nor new", and keep the
                // backup: a leftover file an operator can find beats deleting the
                // last copy of the old state in the name of tidiness.
                backupIsTheOnlyCopy = true;
                throw new AtomicPublishIndeterminateException(
                    path,
                    new AggregateException(replaceFailure, restoreFailure));
            }
            throw;
        }
        finally
        {
            // Best effort by design. A leftover backup is untidy; a publish
            // failed on account of tidying up would be a defect. The one case
            // where the backup is deliberately kept is the case where it holds
            // the only surviving copy of the state.
            try
            {
                if (!backupIsTheOnlyCopy && File.Exists(backup))
                {
                    File.Delete(backup);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    /// <summary>
    /// Raised when a publish could not be completed AND the destination could
    /// not be left holding either the old content or the new. Deliberately a
    /// different type from the timeout: the timeout says "nothing changed, try
    /// again", and a caller that hears that about a missing file will resume
    /// against a path that no longer exists.
    /// </summary>
    internal sealed class AtomicPublishIndeterminateException : Exception
    {
        internal AtomicPublishIndeterminateException(string path, Exception inner)
            : base($"Publishing '{path}' failed and the destination could not be restored to either the old or the " +
                   "new content. This is NOT recoverable by retrying: the state at that path is unknown and must be " +
                   "rebuilt before the run resumes.", inner)
        {
            Path = path;
        }

        internal string Path { get; }

        /// <summary>Always false; named so a caller does not have to know the type.</summary>
        internal bool Recoverable => false;
    }

    private static void PublishWithBoundedRetry(string temporary, string path)
    {
        var gate = GateFor(Path.GetFullPath(path));
        lock (gate)
        {
            var stopwatch = System.Diagnostics.Stopwatch.StartNew();
            var backoff = AtomicPublishInitialBackoffMilliseconds;
            Exception? last = null;
            for (var attempt = 1; attempt <= AtomicPublishMaxAttempts; attempt++)
            {
                try
                {
                    AtomicPublishAttemptHook?.Invoke(path, attempt);
                    PublishOnce(temporary, path);
                    return;
                }
                catch (Exception exception) when (IsTransientSharingViolation(exception, path))
                {
                    last = exception;
                    if (attempt == AtomicPublishMaxAttempts)
                    {
                        break;
                    }
                    Thread.Sleep(backoff);
                    backoff = Math.Min(backoff * 2, AtomicPublishMaxBackoffMilliseconds);
                }
            }

            // THE LAST ATTEMPT IS NOT LIKE THE OTHERS. Every earlier failure is
            // followed by another publish, which is what makes a momentarily
            // absent destination self-correcting. After the final one there is
            // no next attempt, so the absence would be permanent - and the
            // caller would be told, in as many words, that the destination was
            // left unchanged. The invariant is therefore re-established here
            // explicitly rather than assumed: if the path does not resolve, the
            // new content goes there, which is a legal outcome of a publish.
            if (!File.Exists(path))
            {
                try
                {
                    if (File.Exists(temporary))
                    {
                        File.Move(temporary, path, overwrite: true);
                        Interlocked.Increment(ref AtomicPublishRenameCount);
                        return;
                    }
                }
                catch (Exception recovery) when (recovery is IOException or UnauthorizedAccessException)
                {
                    throw new AtomicPublishIndeterminateException(path, recovery);
                }
                throw new AtomicPublishIndeterminateException(path, last!);
            }

            throw new AtomicPublishTimeoutException(path, AtomicPublishMaxAttempts,
                (int)stopwatch.ElapsedMilliseconds, last!);
        }
    }
}
