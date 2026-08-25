namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// Resolves the head of a checkout from files, never from a command.
/// </summary>
/// <remarks>
/// Reading the files rather than shelling out is deliberate. A control plane that
/// asks a command what the head is has to parse the command's text output, which
/// is locale-sensitive, version-sensitive and attacker-influenceable through
/// configuration. The files below are the same data in a form with one meaning.
///
/// A worktree is handled explicitly because that is the ordinary shape here: in a
/// worktree the entry is a file whose content points at the real directory, and a
/// resolver that only understood the directory form would silently report the
/// wrong checkout's head.
/// </remarks>
internal static class GitHead
{
    internal static string Resolve(string repositoryRoot)
    {
        var entry = Path.Combine(repositoryRoot, ".git");
        string gitDirectory;
        if (Directory.Exists(entry))
        {
            gitDirectory = entry;
        }
        else if (File.Exists(entry))
        {
            var pointer = File.ReadAllText(entry, StrictJson.StrictUtf8).Trim();
            const string prefix = "gitdir:";
            if (!pointer.StartsWith(prefix, StringComparison.Ordinal))
            {
                throw new ContractException($"'{entry}' is a file that does not point at a git directory.");
            }
            var target = pointer[prefix.Length..].Trim();
            gitDirectory = Path.IsPathRooted(target) ? target : Path.GetFullPath(Path.Combine(repositoryRoot, target));
        }
        else
        {
            throw new ContractException($"'{repositoryRoot}' is not a git checkout.");
        }

        var headPath = Path.Combine(gitDirectory, "HEAD");
        if (!File.Exists(headPath))
        {
            throw new ContractException($"'{gitDirectory}' holds no HEAD.");
        }
        var head = File.ReadAllText(headPath, StrictJson.StrictUtf8).Trim();
        if (!head.StartsWith("ref:", StringComparison.Ordinal))
        {
            return RequireCommit(head, headPath);
        }

        var reference = head[4..].Trim();
        var loose = Path.Combine(gitDirectory, reference.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(loose))
        {
            return RequireCommit(File.ReadAllText(loose, StrictJson.StrictUtf8).Trim(), loose);
        }

        // A worktree keeps its own HEAD but shares the common directory's refs,
        // so an unresolved reference is looked for there before packed-refs.
        var common = Path.Combine(gitDirectory, "commondir");
        if (File.Exists(common))
        {
            var relative = File.ReadAllText(common, StrictJson.StrictUtf8).Trim();
            var commonDirectory = Path.IsPathRooted(relative)
                ? relative
                : Path.GetFullPath(Path.Combine(gitDirectory, relative));
            var shared = Path.Combine(commonDirectory, reference.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(shared))
            {
                return RequireCommit(File.ReadAllText(shared, StrictJson.StrictUtf8).Trim(), shared);
            }
            var sharedPacked = Path.Combine(commonDirectory, "packed-refs");
            if (File.Exists(sharedPacked))
            {
                var packed = FromPackedRefs(sharedPacked, reference);
                if (packed is not null)
                {
                    return packed;
                }
            }
        }

        var packedRefs = Path.Combine(gitDirectory, "packed-refs");
        if (File.Exists(packedRefs))
        {
            var packed = FromPackedRefs(packedRefs, reference);
            if (packed is not null)
            {
                return packed;
            }
        }
        throw new ContractException($"'{reference}' could not be resolved to a commit under '{gitDirectory}'.");
    }

    private static string? FromPackedRefs(string path, string reference)
    {
        foreach (var line in File.ReadAllLines(path, StrictJson.StrictUtf8))
        {
            if (line.Length == 0 || line[0] is '#' or '^')
            {
                continue;
            }
            var space = line.IndexOf(' ');
            if (space <= 0)
            {
                continue;
            }
            if (string.Equals(line[(space + 1)..].Trim(), reference, StringComparison.Ordinal))
            {
                return RequireCommit(line[..space], path);
            }
        }
        return null;
    }

    private static string RequireCommit(string value, string source)
    {
        var text = value.Trim().ToLowerInvariant();
        if (text.Length != 40 || !StrictJson.IsLowerHex(text))
        {
            throw new ContractException($"'{source}' does not hold a 40-character commit identifier.");
        }
        return text;
    }
}
