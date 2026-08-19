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

    private sealed class TextNode(string value) : Node
    {
        internal override string? AsText => value;

        internal override void Write(StringBuilder builder, bool canonical, int indent) =>
            CanonicalJson.WriteString(value, builder);
    }

    private sealed class NumberNode(long value) : Node
    {
        internal override void Write(StringBuilder builder, bool canonical, int indent) =>
            builder.Append(value.ToString(CultureInfo.InvariantCulture));
    }

    private sealed class FlagNode(bool value) : Node
    {
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
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    internal static string HmacHex(byte[] key, string text) =>
        Convert.ToHexString(HMACSHA256.HashData(key, StrictJson.StrictUtf8.GetBytes(text))).ToLowerInvariant();

    /// <summary>
    /// Replace-in-place through a temporary file in the destination directory, so
    /// a reader never observes a half-written record. Windows and the POSIX hosts
    /// both give a same-directory move replace semantics; a cross-directory one
    /// would not, which is why the temporary is a sibling.
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
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }
}
