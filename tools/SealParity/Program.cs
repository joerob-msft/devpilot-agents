using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal static partial class Program
{
    private const string ContractVersion = "devpilot.seal-parity.v1";
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly JsonSerializerOptions OutputJson = new() { WriteIndented = false };

    public static int Main(string[] args)
    {
        try
        {
            string requestText;
            if (args.Length == 0)
            {
                using var input = new StreamReader(
                    Console.OpenStandardInput(),
                    StrictUtf8,
                    detectEncodingFromByteOrderMarks: true,
                    leaveOpen: false);
                requestText = input.ReadToEnd();
            }
            else if (args.Length == 2 && args[0] == "--request")
            {
                requestText = File.ReadAllText(args[1], StrictUtf8);
            }
            else
            {
                throw new ArgumentException("Usage: SealParity [--request <request.json>]. Without arguments, the request is read from stdin.");
            }

            using var requestDocument = JsonDocument.Parse(requestText, new JsonDocumentOptions { MaxDepth = 128 });
            var request = requestDocument.RootElement;
            RequireObject(request, "request");
            RequireString(request, "contractVersion", ContractVersion);
            var operation = RequireString(request, "operation");
            var profile = RequireString(request, "profile");
            var excluded = ReadExcludedProperties(request);

            var canonical = profile == "exact-text-v1"
                ? ReadExactText(request)
                : Canonicalize(ReadJsonInput(request), profile, excluded);
            var bytes = StrictUtf8.GetBytes(canonical);
            var sha256 = Hex(SHA256.HashData(bytes));

            string? hmac = null;
            if (operation == "hmac-sha256")
            {
                var key = ReadKey(request);
                foreach (var domain in ReadDomains(request))
                {
                    key = HMACSHA256.HashData(key, StrictUtf8.GetBytes(domain));
                }
                hmac = Hex(HMACSHA256.HashData(key, bytes));
            }
            else if (operation is not ("canonicalize" or "sha256"))
            {
                throw new ArgumentException($"Unsupported operation '{operation}'.");
            }

            var output = new Dictionary<string, object?>
            {
                ["contractVersion"] = ContractVersion,
                ["operation"] = operation,
                ["profile"] = profile,
                ["canonicalText"] = canonical,
                ["canonicalUtf8Base64"] = Convert.ToBase64String(bytes),
                ["byteLength"] = bytes.Length,
                ["sha256"] = sha256
            };
            if (hmac is not null)
            {
                output["hmacSha256"] = hmac;
            }

            var responseBytes = StrictUtf8.GetBytes(JsonSerializer.Serialize(output, OutputJson));
            using var standardOutput = Console.OpenStandardOutput();
            standardOutput.Write(responseBytes);
            return 0;
        }
        catch (Exception exception) when (exception is ArgumentException
                                          or FormatException
                                          or InvalidDataException
                                          or JsonException
                                          or DecoderFallbackException
                                          or EncoderFallbackException
                                          or InvalidOperationException
                                          or OverflowException)
        {
            Console.Error.WriteLine(exception.Message);
            return 2;
        }
    }

    private static JsonElement ReadJsonInput(JsonElement request)
    {
        if (request.TryGetProperty("inputFile", out var inputFile))
        {
            if (inputFile.ValueKind != JsonValueKind.String)
            {
                throw new ArgumentException("'inputFile' must be a string.");
            }
            var text = File.ReadAllText(inputFile.GetString()!, StrictUtf8);
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 64 });
            return document.RootElement.Clone();
        }
        if (!request.TryGetProperty("value", out var value))
        {
            throw new ArgumentException("A JSON profile requires 'value' or 'inputFile'.");
        }
        return value.Clone();
    }

    private static string ReadExactText(JsonElement request)
    {
        if (request.TryGetProperty("inputFile", out var inputFile))
        {
            if (inputFile.ValueKind != JsonValueKind.String)
            {
                throw new ArgumentException("'inputFile' must be a string.");
            }
            return File.ReadAllText(inputFile.GetString()!, StrictUtf8);
        }
        return RequireString(request, "text");
    }

    private static HashSet<string> ReadExcludedProperties(JsonElement request)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (!request.TryGetProperty("excludeRootProperties", out var excluded))
        {
            return result;
        }
        if (excluded.ValueKind != JsonValueKind.Array)
        {
            throw new ArgumentException("'excludeRootProperties' must be an array of strings.");
        }
        foreach (var item in excluded.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || !result.Add(item.GetString()!))
            {
                throw new ArgumentException("'excludeRootProperties' must contain unique strings.");
            }
        }
        return result;
    }

    private static byte[] ReadKey(JsonElement request)
    {
        if (!request.TryGetProperty("key", out var key))
        {
            throw new ArgumentException("The HMAC operation requires 'key'.");
        }
        RequireObject(key, "key");
        var format = RequireString(key, "format");
        return format switch
        {
            "hex" => Convert.FromHexString(RequireString(key, "value")),
            "base64" => Convert.FromBase64String(RequireString(key, "value")),
            "utf8" => StrictUtf8.GetBytes(RequireString(key, "value")),
            "raw-file" => File.ReadAllBytes(RequireString(key, "path")),
            "stored-raw" => ReadStoredRawKey(RequireString(key, "value")),
            "stored-file" => ReadStoredRawKey(File.ReadAllText(RequireString(key, "path"), StrictUtf8).Trim()),
            _ => throw new ArgumentException($"Unsupported key format '{format}'.")
        };
    }

    private static byte[] ReadStoredRawKey(string value)
    {
        const string prefix = "raw:";
        if (!value.StartsWith(prefix, StringComparison.Ordinal))
        {
            throw new ArgumentException("The 'stored-raw' key format requires the production 'raw:<base64>' representation; DPAPI material is intentionally not decrypted by this spike.");
        }
        return Convert.FromBase64String(value[prefix.Length..]);
    }

    private static IEnumerable<string> ReadDomains(JsonElement request)
    {
        if (!request.TryGetProperty("domains", out var domains))
        {
            yield break;
        }
        if (domains.ValueKind != JsonValueKind.Array)
        {
            throw new ArgumentException("'domains' must be an array of strings.");
        }
        foreach (var domain in domains.EnumerateArray())
        {
            if (domain.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(domain.GetString()))
            {
                throw new ArgumentException("'domains' must contain non-empty strings.");
            }
            yield return domain.GetString()!;
        }
    }

    private static string Canonicalize(JsonElement value, string profile, HashSet<string> excluded)
    {
        var builder = new StringBuilder();
        switch (profile)
        {
            case "json-text-v1":
                WriteCanonical(value, builder, 0, 64, NumberMode.Raw, StringMode.PowerShell, ObjectMode.TextPowerShell, excluded);
                break;
            case "replay-v1":
                WriteCanonical(value, builder, 0, 24, NumberMode.ReplayInteger, StringMode.Replay, ObjectMode.PowerShellHashtable, excluded);
                break;
            case "convention-v1":
                WriteCanonical(value, builder, 0, 32, NumberMode.PowerShellObject, StringMode.PowerShell, ObjectMode.PowerShellHashtable, excluded);
                break;
            default:
                throw new ArgumentException($"Unsupported profile '{profile}'.");
        }
        return builder.ToString();
    }

    private static void WriteCanonical(
        JsonElement value,
        StringBuilder builder,
        int depth,
        int maximumDepth,
        NumberMode numberMode,
        StringMode stringMode,
        ObjectMode objectMode,
        HashSet<string>? rootExclusions)
    {
        if (depth > maximumDepth)
        {
            throw new InvalidDataException($"Canonical JSON exceeded depth {maximumDepth}.");
        }

        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                var properties = value.EnumerateObject().ToArray();
                var comparer = objectMode == ObjectMode.TextPowerShell
                    ? StringComparer.OrdinalIgnoreCase
                    : StringComparer.Ordinal;
                var lastValues = new Dictionary<string, JsonElement>(comparer);
                foreach (var property in properties)
                {
                    lastValues[property.Name] = property.Value;
                }
                var names = properties
                    .Where(property => depth != 0 || rootExclusions is null || !rootExclusions.Contains(property.Name))
                    .Select(property => property.Name);
                if (objectMode == ObjectMode.PowerShellHashtable)
                {
                    names = names.Distinct(StringComparer.Ordinal);
                }
                var sortedNames = names.Order(StringComparer.Ordinal).ToArray();
                builder.Append('{');
                for (var index = 0; index < sortedNames.Length; index++)
                {
                    if (index != 0)
                    {
                        builder.Append(',');
                    }
                    WriteString(sortedNames[index], builder, stringMode);
                    builder.Append(':');
                    WriteCanonical(lastValues[sortedNames[index]], builder, depth + 1, maximumDepth, numberMode, stringMode, objectMode, null);
                }
                builder.Append('}');
                break;
            case JsonValueKind.Array:
                builder.Append('[');
                var first = true;
                foreach (var item in value.EnumerateArray())
                {
                    if (!first)
                    {
                        builder.Append(',');
                    }
                    first = false;
                    WriteCanonical(item, builder, depth + 1, maximumDepth, numberMode, stringMode, objectMode, null);
                }
                builder.Append(']');
                break;
            case JsonValueKind.String:
                var text = value.GetString()!;
                if (numberMode == NumberMode.ReplayInteger &&
                    ((ExtendedIsoTimestamp().IsMatch(text) &&
                      DateTime.TryParse(
                          text,
                          CultureInfo.InvariantCulture,
                          DateTimeStyles.RoundtripKind,
                          out _)) ||
                     MicrosoftJsonTimestamp().IsMatch(text)))
                {
                    throw new InvalidDataException("Replay canonical JSON does not accept extended ISO-8601 date values; use the basic yyyyMMddTHHmmssZ string form.");
                }
                WriteString(text, builder, stringMode);
                break;
            case JsonValueKind.Number:
                builder.Append(FormatNumber(value.GetRawText(), numberMode));
                break;
            case JsonValueKind.True:
                builder.Append("true");
                break;
            case JsonValueKind.False:
                builder.Append("false");
                break;
            case JsonValueKind.Null:
                builder.Append("null");
                break;
            default:
                throw new InvalidDataException($"Unsupported JSON kind '{value.ValueKind}'.");
        }
    }

    private static string FormatNumber(string raw, NumberMode mode)
    {
        if (mode == NumberMode.Raw)
        {
            return raw;
        }

        var isIntegerToken = raw.IndexOfAny(['.', 'e', 'E']) < 0;
        if (mode == NumberMode.ReplayInteger)
        {
            if (!isIntegerToken || !long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer))
            {
                throw new InvalidDataException("Replay canonical JSON accepts only signed 64-bit integer tokens.");
            }
            return integer.ToString(CultureInfo.InvariantCulture);
        }

        if (isIntegerToken)
        {
            return BigInteger.Parse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture)
                .ToString(CultureInfo.InvariantCulture);
        }
        var floating = double.Parse(raw, NumberStyles.Float, CultureInfo.InvariantCulture);
        if (double.IsPositiveInfinity(floating))
        {
            return "Infinity";
        }
        if (double.IsNegativeInfinity(floating))
        {
            return "-Infinity";
        }
        return Convert.ToString(floating, CultureInfo.InvariantCulture);
    }

    private static void WriteString(string value, StringBuilder builder, StringMode mode)
    {
        if (mode == StringMode.PowerShell)
        {
            WritePowerShellString(value, builder);
            return;
        }

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

    private static void WritePowerShellString(string value, StringBuilder builder)
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
                    if (character < 32 || character is '\u0085' or '\u2028' or '\u2029')
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

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

    private static void RequireObject(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new ArgumentException($"'{name}' must be an object.");
        }
    }

    private static string RequireString(JsonElement value, string propertyName, string? expected = null)
    {
        if (!value.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException($"'{propertyName}' must be a string.");
        }
        var result = property.GetString()!;
        if (expected is not null && result != expected)
        {
            throw new ArgumentException($"Unsupported contract version '{result}'.");
        }
        return result;
    }

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}(?::?\d{2})?)?$", RegexOptions.CultureInvariant)]
    private static partial Regex ExtendedIsoTimestamp();

    [GeneratedRegex(@"^/Date\(-?\d+(?:[+-]\d{4})?\)/$", RegexOptions.CultureInvariant)]
    private static partial Regex MicrosoftJsonTimestamp();

    private enum NumberMode
    {
        Raw,
        ReplayInteger,
        PowerShellObject
    }

    private enum StringMode
    {
        PowerShell,
        Replay
    }

    private enum ObjectMode
    {
        TextPowerShell,
        PowerShellHashtable
    }
}
