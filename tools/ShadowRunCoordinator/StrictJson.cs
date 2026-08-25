using System.Globalization;
using System.Text;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Thrown for every input the coordinator refuses. Carrying one type means the
/// entry point cannot accidentally map a refusal onto the success path.
/// </summary>
internal sealed class ContractException : Exception
{
    public ContractException(string message) : base(message)
    {
    }
}

/// <summary>
/// The only door JSON comes through.
/// </summary>
/// <remarks>
/// Every rule here exists because the PowerShell side already learned it the
/// hard way and wrote it down in docs/stage-file-contract.md: a byte order mark
/// means the file was produced by a path that does not honour the contract, a
/// truncated file must not read as an empty result, a scalar where an object was
/// declared is the collapse the contract exists to prevent, and an unknown field
/// is how a contract drifts. The reader repairs nothing. Reading is fail-closed
/// in both directions: a missing field and a present-but-wrong-shaped field are
/// both refusals, and they are refused with different messages so a caller can
/// tell absent from empty.
/// </remarks>
internal static class StrictJson
{
    /// <summary>UTF-8 that throws rather than substituting U+FFFD for invalid bytes.</summary>
    internal static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private static readonly JsonDocumentOptions DocumentOptions = new()
    {
        MaxDepth = 64,
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow
    };

    /// <summary>
    /// Reads a JSON object out of a file, refusing everything the stage file
    /// contract refuses. The returned element is cloned, so the caller may keep
    /// it after the document is disposed.
    /// </summary>
    internal static JsonElement ReadObjectFile(string path, string label, long maximumBytes = 32L * 1024 * 1024)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ContractException($"The {label} path is empty.");
        }
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            throw new ContractException($"The {label} file '{path}' does not exist.");
        }
        if (info.Length == 0)
        {
            throw new ContractException($"The {label} file '{path}' is empty; a partial write must not read as an empty result.");
        }
        if (info.Length > maximumBytes)
        {
            throw new ContractException($"The {label} file '{path}' is {info.Length} bytes, above the {maximumBytes} byte limit.");
        }

        return ReadObjectBytes(File.ReadAllBytes(path), path, label);
    }

    /// <summary>
    /// Reads a JSON object out of bytes the caller already holds, applying every
    /// rule <see cref="ReadObjectFile"/> applies.
    /// </summary>
    /// <remarks>
    /// A caller that must both digest a contract file and obey it has to do both
    /// to the same bytes. Reading the file twice - once to hash, once to parse -
    /// leaves a window in which the bytes that were proven and the bytes that are
    /// obeyed are not the same bytes, and a digest that attests to a file nobody
    /// read is worse than no digest at all. So the bytes are read once and passed
    /// in here.
    /// </remarks>
    internal static JsonElement ReadObjectBytes(byte[] bytes, string path, string label)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        if (bytes.Length == 0)
        {
            throw new ContractException($"The {label} file '{path}' is empty; a partial write must not read as an empty result.");
        }
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        {
            throw new ContractException($"The {label} file '{path}' starts with a UTF-8 byte order mark; the contract is UTF-8 without one.");
        }

        string text;
        try
        {
            text = StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException exception)
        {
            throw new ContractException($"The {label} file '{path}' is not valid UTF-8: {exception.Message}");
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            throw new ContractException($"The {label} file '{path}' holds only whitespace.");
        }

        // Checked before parsing so that a truncated object and a stream that
        // printed something before the JSON are refused by name rather than as a
        // generic parse error. A diagnostic line a well-meaning helper wrote is
        // the exact fault the file contract exists to catch.
        var trimmed = text.Trim();
        if (trimmed[0] != '{')
        {
            throw new ContractException($"The {label} file '{path}' does not begin with a JSON object; nothing may write to a contract file but its writer.");
        }
        if (trimmed[^1] != '}')
        {
            throw new ContractException($"The {label} file '{path}' does not end with a JSON object; it is truncated or something was appended to it.");
        }

        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(text, DocumentOptions);
            root = document.RootElement.Clone();
        }
        catch (JsonException exception)
        {
            throw new ContractException($"The {label} file '{path}' is not parsable JSON: {exception.Message}");
        }

        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} file '{path}' is a {Describe(root.ValueKind)}, not an object.");
        }
        return root;
    }

    /// <summary>
    /// Refuses any property the caller did not enumerate. Silent extension is
    /// how contracts drift, so an unknown field is a rejection rather than a
    /// forward-compatible extra.
    /// </summary>
    internal static void RequireNoUnknownFields(JsonElement value, string label, params string[] known)
    {
        var allowed = new HashSet<string>(known, StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!allowed.Contains(property.Name))
            {
                throw new ContractException($"The {label} carries unknown field '{property.Name}'.");
            }
        }
    }

    internal static JsonElement RequireObject(JsonElement parent, string name, string label)
    {
        if (!parent.TryGetProperty(name, out var value))
        {
            throw new ContractException($"The {label} is missing required field '{name}'.");
        }
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} field '{name}' is a {Describe(value.ValueKind)}, not an object.");
        }
        return value;
    }

    internal static string RequireString(JsonElement parent, string name, string label)
    {
        if (!parent.TryGetProperty(name, out var value))
        {
            throw new ContractException($"The {label} is missing required field '{name}'.");
        }
        if (value.ValueKind != JsonValueKind.String)
        {
            throw new ContractException($"The {label} field '{name}' is a {Describe(value.ValueKind)}, not a string.");
        }
        var text = value.GetString()!;
        if (text.Length == 0)
        {
            throw new ContractException($"The {label} field '{name}' is an empty string.");
        }
        return text;
    }

    internal static string RequireLiteral(JsonElement parent, string name, string expected, string label)
    {
        var actual = RequireString(parent, name, label);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new ContractException($"The {label} field '{name}' is '{actual}', and the only value this build understands is '{expected}'.");
        }
        return actual;
    }

    internal static int RequireInt(JsonElement parent, string name, string label, int minimum, int maximum)
    {
        if (!parent.TryGetProperty(name, out var value))
        {
            throw new ContractException($"The {label} is missing required field '{name}'.");
        }
        if (value.ValueKind != JsonValueKind.Number)
        {
            throw new ContractException($"The {label} field '{name}' is a {Describe(value.ValueKind)}, not a number.");
        }
        if (!value.TryGetInt32(out var number))
        {
            throw new ContractException($"The {label} field '{name}' is not a 32-bit integer.");
        }
        if (number < minimum || number > maximum)
        {
            throw new ContractException($"The {label} field '{name}' is {number.ToString(CultureInfo.InvariantCulture)}, outside [{minimum}, {maximum}].");
        }
        return number;
    }

    internal static bool RequireBool(JsonElement parent, string name, string label)
    {
        if (!parent.TryGetProperty(name, out var value))
        {
            throw new ContractException($"The {label} is missing required field '{name}'.");
        }
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new ContractException($"The {label} field '{name}' is a {Describe(value.ValueKind)}, not a boolean.");
        }
        return value.GetBoolean();
    }

    /// <summary>
    /// A declared collection. Absent and empty are different facts, so an absent
    /// field is refused rather than defaulted, and a bare scalar or a null is
    /// refused rather than wrapped: this reader is the consuming half of the
    /// contract, and the consuming half rejects rather than repairs.
    /// </summary>
    internal static IReadOnlyList<JsonElement> RequireArray(JsonElement parent, string name, string label)
    {
        if (!parent.TryGetProperty(name, out var value))
        {
            throw new ContractException($"The {label} is missing required collection field '{name}'; absent is not empty.");
        }
        if (value.ValueKind != JsonValueKind.Array)
        {
            throw new ContractException($"The {label} collection field '{name}' lost collection shape: it is a {Describe(value.ValueKind)}.");
        }
        var items = new List<JsonElement>();
        foreach (var item in value.EnumerateArray())
        {
            items.Add(item);
        }
        return items;
    }

    internal static IReadOnlyList<string> RequireStringArray(JsonElement parent, string name, string label)
    {
        var items = RequireArray(parent, name, label);
        var result = new List<string>(items.Count);
        for (var index = 0; index < items.Count; index++)
        {
            if (items[index].ValueKind != JsonValueKind.String)
            {
                throw new ContractException($"The {label} collection field '{name}' holds a {Describe(items[index].ValueKind)} at index {index.ToString(CultureInfo.InvariantCulture)}, not a string.");
            }
            result.Add(items[index].GetString()!);
        }
        return result;
    }

    internal static string RequireHex(JsonElement parent, string name, string label, int length)
    {
        var text = RequireString(parent, name, label);
        if (text.Length != length || !IsLowerHex(text))
        {
            throw new ContractException($"The {label} field '{name}' is not {length.ToString(CultureInfo.InvariantCulture)} lower-case hexadecimal characters.");
        }
        return text;
    }

    internal static bool IsLowerHex(string text)
    {
        foreach (var character in text)
        {
            var isDigit = character is >= '0' and <= '9';
            var isLower = character is >= 'a' and <= 'f';
            if (!isDigit && !isLower)
            {
                return false;
            }
        }
        return text.Length > 0;
    }

    internal static string Describe(JsonValueKind kind) => kind switch
    {
        JsonValueKind.Object => "object",
        JsonValueKind.Array => "array",
        JsonValueKind.String => "string",
        JsonValueKind.Number => "number",
        JsonValueKind.True => "boolean",
        JsonValueKind.False => "boolean",
        JsonValueKind.Null => "null",
        _ => "undefined value"
    };
}
