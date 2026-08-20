using System.Globalization;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The versioned manifest that binds one operator-initiated cohort to the exact
/// set of subjects it is allowed to prepare, in the exact order it prepares them.
/// </summary>
/// <remarks>
/// A cohort is not a new capability. It is the SAME typed preparation this
/// program already performs, run once per declared entry, one at a time, with a
/// per-entry immutable output root - so everything a single preparation refuses,
/// a cohort refuses too, and the manifest exists only to say which preparations
/// were authorized and what the whole set is allowed to consume.
///
/// Three properties are the reason this is a file rather than a command line.
///
/// It is complete from the moment it is written. Every entry, every identity pin,
/// every digest and every budget is present before anything starts, so a cohort
/// cannot grow a subject halfway through, and the digest of these bytes is what
/// the journal binds to - a manifest that gained an entry is a different manifest
/// and refuses to resume.
///
/// It is a refusal wearing the shape of a setting wherever a permissive value
/// would be dangerous. Concurrency is a literal one, the authorization kind is a
/// literal this build accepts exactly one value for, and the provider write
/// budget is a literal zero. There is no permissive value to write.
///
/// It carries no judgement. There is no prompt here, no rule, no severity and no
/// verdict; the model arguments a slot runs stay where they already are, inside
/// the per-entry request's opaque plan, and this file never reads them.
/// </remarks>
internal sealed record CohortManifest
{
    internal const string ContractVersionValue = "devpilot.shadow-cohort.manifest.v1";
    internal const string KindValue = "shadow-cohort-run";

    /// <summary>The only concurrency this build runs a cohort at.</summary>
    /// <remarks>
    /// One. A second concurrent entry would put two typed coordinators, two
    /// leases and two sets of children in flight against one toolkit head, and
    /// the accounting that makes a hard budget stop meaningful - actual counts
    /// accumulated from entries that have ALREADY ended - would be reading a
    /// moving total. A manifest asking for more is refused at load rather than
    /// clamped, because clamping would silently run a cohort nobody declared.
    /// </remarks>
    internal const int SupportedConcurrency = 1;

    /// <summary>Stop after the first entry that ends other than successfully.</summary>
    internal const string StopPolicyFailFast = "failFast";

    /// <summary>Carry on to the next declared entry after an unsuccessful one.</summary>
    internal const string StopPolicyContinue = "continueOnTerminalFailure";

    internal required string CohortId { get; init; }

    internal required string CorrelationId { get; init; }

    internal required string ToolkitRoot { get; init; }

    internal required string ToolkitHead { get; init; }

    internal required string RequiredRef { get; init; }

    internal required CohortExecution Execution { get; init; }

    internal required CohortBudgets Budgets { get; init; }

    /// <summary>Where the signed journal, the lease and the launch intents live.</summary>
    internal required string JournalRoot { get; init; }

    /// <summary>Where the ordered, self-hashed cohort index is published.</summary>
    internal required string IndexPath { get; init; }

    /// <summary>The declared entries, in the only order this cohort runs them.</summary>
    internal required IReadOnlyList<CohortEntry> Entries { get; init; }

    /// <summary>The digest of the exact manifest bytes, so a journal cannot be resumed under a different manifest.</summary>
    internal required string ManifestSha256 { get; init; }

    internal string JournalPath => Path.Combine(JournalRoot, "cohort-journal.json");

    internal string JournalKeyPath => Path.Combine(JournalRoot, "cohort-journal.key");

    internal string LeasePath => Path.Combine(JournalRoot, "cohort.lease");

    internal string IntentRoot => Path.Combine(JournalRoot, "intents");

    internal string LogRoot => Path.Combine(JournalRoot, "logs");

    internal static CohortManifest Load(string path)
    {
        const string label = "shadow cohort manifest";
        var bytes = ReadBytes(path, label);
        var root = StrictJson.ReadObjectBytes(bytes, path, label);
        StrictJson.RequireNoUnknownFields(
            root,
            label,
            "contractVersion",
            "kind",
            "cohortId",
            "correlationId",
            "toolkit",
            "execution",
            "budgets",
            "journal",
            "audit",
            "entries");

        StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, label);
        StrictJson.RequireLiteral(root, "kind", KindValue, label);

        var cohortId = StrictJson.RequireString(root, "cohortId", label);
        RequireOpaqueShape(cohortId, label, "cohortId", 8, 64);
        var correlationId = StrictJson.RequireString(root, "correlationId", label);
        RequireOpaqueShape(correlationId, label, "correlationId", 8, 64);

        var toolkit = StrictJson.RequireObject(root, "toolkit", label);
        StrictJson.RequireNoUnknownFields(toolkit, label + " toolkit", "repositoryRoot", "head", "requiredRef");

        var execution = CohortExecution.Read(StrictJson.RequireObject(root, "execution", label), label + " execution");
        var budgets = CohortBudgets.Read(StrictJson.RequireObject(root, "budgets", label), label + " budgets");

        var journal = StrictJson.RequireObject(root, "journal", label);
        StrictJson.RequireNoUnknownFields(journal, label + " journal", "root");
        var audit = StrictJson.RequireObject(root, "audit", label);
        StrictJson.RequireNoUnknownFields(audit, label + " audit", "indexPath");

        var entryNodes = StrictJson.RequireArray(root, "entries", label);
        if (entryNodes.Count == 0)
        {
            throw new ContractException($"The {label} declares no entries. A cohort that prepares nothing is not a cohort; absent is not empty and empty is not a run.");
        }
        var entries = new List<CohortEntry>(entryNodes.Count);
        for (var index = 0; index < entryNodes.Count; index++)
        {
            entries.Add(CohortEntry.Read(
                entryNodes[index],
                $"{label} entries[{index.ToString(CultureInfo.InvariantCulture)}]",
                index + 1));
        }

        RequireDistinctEntries(entries, label);

        // The declared size is checked against the declared ceiling here, before
        // any entry is admitted, so a cohort that could never finish inside its
        // own budget is refused rather than discovered at the last entry.
        if (entries.Count > budgets.MaximumPullRequests)
        {
            throw new ContractException(
                $"The {label} declares {entries.Count.ToString(CultureInfo.InvariantCulture)} entries and a ceiling of " +
                $"{budgets.MaximumPullRequests.ToString(CultureInfo.InvariantCulture)}. A cohort is refused rather than truncated: " +
                "the entries that would not run are entries an operator believed were authorized.");
        }

        RequireEstimatesWithinBudget(entries, budgets, label);

        var manifest = new CohortManifest
        {
            CohortId = cohortId,
            CorrelationId = correlationId,
            ToolkitRoot = StrictJson.RequireString(toolkit, "repositoryRoot", label + " toolkit"),
            ToolkitHead = StrictJson.RequireHex(toolkit, "head", label + " toolkit", 40),
            RequiredRef = StrictJson.RequireString(toolkit, "requiredRef", label + " toolkit"),
            Execution = execution,
            Budgets = budgets,
            JournalRoot = RequireRootedPath(StrictJson.RequireString(journal, "root", label + " journal"), "journal root", label),
            IndexPath = RequireRootedPath(StrictJson.RequireString(audit, "indexPath", label + " audit"), "audit index path", label),
            Entries = entries,
            ManifestSha256 = CanonicalJson.Sha256Hex(bytes)
        };
        RequireIndexIsolated(manifest, label, path);
        return manifest;
    }

    /// <summary>
    /// Refuses an index declared on top of something the cohort has to be able to
    /// read afterwards.
    /// </summary>
    /// <remarks>
    /// The index is the one file this runner replaces wholesale on every publish,
    /// and it is published repeatedly, including while the walk is still going. An
    /// index declared over the journal, the journal's key, the lease, the manifest
    /// itself, a sealed request, a declared rule bundle or an entry's output root
    /// would therefore destroy the very record the index claims to be derived
    /// from, and the destruction would happen before anyone read either. The
    /// manifest and the rule bundles matter as much as the journal here: the first
    /// publish happens before the entries are verified, so an index declared over
    /// one of them would be checked against a file this runner had already
    /// overwritten.
    /// </remarks>
    private static void RequireIndexIsolated(CohortManifest manifest, string label, string manifestPath)
    {
        var index = NormalizeRoot(manifest.IndexPath);
        foreach (var (path, what) in new[]
        {
            (manifest.JournalPath, "the cohort journal"),
            (manifest.JournalKeyPath, "the cohort journal's signing key"),
            (manifest.LeasePath, "the cohort lease"),
            (manifest.IntentRoot, "the cohort intent root"),
            (manifest.LogRoot, "the cohort log root"),
            (manifestPath, "this manifest")
        })
        {
            if (string.Equals(index, NormalizeRoot(path), StringComparison.OrdinalIgnoreCase))
            {
                throw new ContractException(
                    $"The {label} declares its audit index at '{manifest.IndexPath}', which is {what}. The index is rewritten on every " +
                    "publish, so declaring it over the record it is derived from would destroy that record.");
            }
        }
        foreach (var entry in manifest.Entries)
        {
            var root = NormalizeRoot(entry.OutputRoot);
            if (string.Equals(index, root, StringComparison.OrdinalIgnoreCase)
                || index.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                throw new ContractException(
                    $"The {label} declares its audit index at '{manifest.IndexPath}', inside entry '{entry.EntryId}'s output root. " +
                    "An entry's output root holds that preparation's own sealed evidence and nothing this cohort writes across it.");
            }
            if (string.Equals(index, NormalizeRoot(entry.RequestPath), StringComparison.OrdinalIgnoreCase))
            {
                throw new ContractException(
                    $"The {label} declares its audit index at '{manifest.IndexPath}', which is entry '{entry.EntryId}'s sealed request.");
            }
            if (string.Equals(index, NormalizeRoot(entry.RuleBundlePath), StringComparison.OrdinalIgnoreCase))
            {
                throw new ContractException(
                    $"The {label} declares its audit index at '{manifest.IndexPath}', which is the rule bundle declaration entry " +
                    $"'{entry.EntryId}' is pinned to. A bundle overwritten by the first publish is a bundle no entry could be verified against.");
            }
        }
    }

    /// <summary>
    /// The binding a journal is signed over: what this cohort is, what it may
    /// consume, and the ordered identity of every entry - by digest, never by
    /// subject.
    /// </summary>
    internal MapNode Describe()
    {
        var entries = new ListNode();
        foreach (var entry in Entries)
        {
            entries.Add(entry.Describe());
        }
        return new MapNode()
            .Set("cohortId", CohortId)
            .Set("correlationId", CorrelationId)
            .Set("toolkitHead", ToolkitHead)
            .Set("requiredRef", RequiredRef)
            .Set("concurrency", Execution.Concurrency)
            .Set("stopPolicy", Execution.StopPolicy)
            .Set("authorizationKind", Execution.AuthorizationKind)
            .Set("budgets", Budgets.Describe())
            .Set("declaredEntryCount", Entries.Count)
            .Set("entries", entries);
    }

    /// <summary>The declared entry carrying an identifier, or a refusal.</summary>
    internal CohortEntry RequireEntry(string entryId)
    {
        foreach (var entry in Entries)
        {
            if (string.Equals(entry.EntryId, entryId, StringComparison.Ordinal))
            {
                return entry;
            }
        }
        throw new ContractException(
            $"This cohort declares no entry '{entryId}'. A journal naming an entry the manifest does not declare is a journal from another cohort.");
    }

    private static byte[] ReadBytes(string path, string label)
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
        if (info.Length > 8L * 1024 * 1024)
        {
            throw new ContractException($"The {label} file '{path}' is {info.Length.ToString(CultureInfo.InvariantCulture)} bytes, above the 8388608 byte limit.");
        }
        return File.ReadAllBytes(path);
    }

    /// <summary>
    /// Refuses the three ways one cohort can collide with itself: two entries
    /// under one handle, two entries naming one pull request, and two entries
    /// sharing an output root.
    /// </summary>
    /// <remarks>
    /// Each is checked in the manifest rather than at the entry that would
    /// discover it. A duplicate pull request would be a second preparation of a
    /// subject whose first preparation is already immutable evidence; a shared
    /// output root would make the second entry's coordinator refuse - or worse,
    /// resume - against a root the first one owns. Neither is something a run
    /// halfway through a cohort can recover from, so neither is allowed to start.
    /// </remarks>
    private static void RequireDistinctEntries(IReadOnlyList<CohortEntry> entries, string label)
    {
        var handles = new HashSet<string>(StringComparer.Ordinal);
        var subjects = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in entries)
        {
            if (!handles.Add(entry.EntryId))
            {
                throw new ContractException($"The {label} declares entry '{entry.EntryId}' twice; one handle names one preparation.");
            }
            var subject = string.Join(
                '/',
                entry.Organization,
                entry.Project,
                entry.Repository,
                entry.PullRequestId.ToString(CultureInfo.InvariantCulture),
                entry.IterationId.ToString(CultureInfo.InvariantCulture));
            if (!subjects.Add(subject))
            {
                throw new ContractException(
                    $"The {label} declares pull request {entry.PullRequestId.ToString(CultureInfo.InvariantCulture)} iteration " +
                    $"{entry.IterationId.ToString(CultureInfo.InvariantCulture)} more than once. A cohort prepares a subject once; " +
                    "a second preparation of it would run beside evidence that is already immutable.");
            }
            var root = NormalizeRoot(entry.OutputRoot);
            if (!roots.Add(root))
            {
                throw new ContractException(
                    $"The {label} gives more than one entry the output root '{entry.OutputRoot}'. " +
                    "Two preparations that share a root are not two preparations, and the second would resume onto the first's record.");
            }
        }
    }

    /// <summary>
    /// Refuses a cohort whose own sealed estimates already exceed what it says it
    /// may consume.
    /// </summary>
    /// <remarks>
    /// The admission check before each entry is the one that actually stops a
    /// run, and it uses accumulated ACTUAL counts. This is the cheaper claim made
    /// at load: a cohort whose declared estimates cannot fit was mis-declared,
    /// and telling an operator that before the first entry starts is better than
    /// telling them after the third one has produced evidence that will now be
    /// abandoned.
    /// </remarks>
    private static void RequireEstimatesWithinBudget(IReadOnlyList<CohortEntry> entries, CohortBudgets budgets, string label)
    {
        long models = 0;
        long verifiers = 0;
        long seconds = 0;
        foreach (var entry in entries)
        {
            models += entry.EstimatedModelStarts;
            verifiers += entry.EstimatedVerifierAssignments;
            seconds += entry.EstimatedWallClockSeconds;
        }
        RequireFits(models, budgets.MaximumModelStarts, "model start", label);
        RequireFits(verifiers, budgets.MaximumVerifierAssignments, "verifier assignment", label);
        RequireFits(seconds, budgets.MaximumWallClockSeconds, "wall clock second", label);
    }

    private static void RequireFits(long declared, int ceiling, string unit, string label)
    {
        if (declared > ceiling)
        {
            throw new ContractException(
                $"The {label} declares {declared.ToString(CultureInfo.InvariantCulture)} estimated {unit}(s) across its entries and a ceiling of " +
                $"{ceiling.ToString(CultureInfo.InvariantCulture)}. The estimates are sealed with the manifest, so a cohort that cannot fit inside its own " +
                "ceiling is refused before it starts rather than stopped partway through.");
        }
    }

    /// <summary>
    /// A path compared the way two entries colliding on one root would collide:
    /// fully resolved, and without a trailing separator deciding the answer.
    /// </summary>
    internal static string NormalizeRoot(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    /// <summary>
    /// A declared location that means the same thing wherever it is read from.
    /// </summary>
    /// <remarks>
    /// A relative path resolves against whatever directory the process happened
    /// to start in, so the same manifest run twice from two places would write two
    /// journals and two indexes - and a resume pointed at the wrong one would read
    /// an empty journal and start entries that already ran. The entry paths are
    /// held to the same rule for a sharper reason: the child preparation is
    /// started with its working directory set to the toolkit checkout, so a
    /// relative output root would be validated by the parent against one directory
    /// and written by the child into another. Rooted is not enough: on Windows both
    /// a drive-relative path and a root-relative one are rooted and still resolve
    /// against the current directory. The value is returned fully resolved so that
    /// everything downstream compares the same string.
    /// </remarks>
    internal static string RequireRootedPath(string path, string field, string label)
    {
        if (!Path.IsPathFullyQualified(path))
        {
            throw new ContractException(
                $"The {label} declares a {field} '{path}' that is not fully qualified. Where a cohort reads and writes cannot depend " +
                "on which directory or which drive a run was started from, because a resume that read a different journal would start " +
                "entries that already ran, and a child started elsewhere would publish its evidence somewhere nobody looks. " +
                "Declare a fully qualified absolute path.");
        }
        return Path.GetFullPath(path);
    }

    /// <summary>
    /// The shape every opaque handle in this contract carries.
    /// </summary>
    /// <remarks>
    /// These strings go into file names, journal records and log lines, so they
    /// are constrained to something that cannot inject a path separator, a shell
    /// metacharacter or a newline into any of the three. The constraint is on
    /// shape alone: what a handle MEANS is the operator's business and nothing
    /// here reads it.
    /// </remarks>
    internal static void RequireOpaqueShape(string value, string label, string field, int minimum, int maximum)
    {
        if (value.Length < minimum || value.Length > maximum)
        {
            throw new ContractException(
                $"The {label} field '{field}' must be {minimum.ToString(CultureInfo.InvariantCulture)} to " +
                $"{maximum.ToString(CultureInfo.InvariantCulture)} characters.");
        }
        foreach (var character in value)
        {
            var ok = character is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '-';
            if (!ok)
            {
                throw new ContractException($"The {label} field '{field}' accepts only letters, digits and hyphens.");
            }
        }
    }
}

/// <summary>
/// How the cohort runs, as opposed to what it runs.
/// </summary>
/// <remarks>
/// The launch command is carried, never interpreted. What this section holds is
/// a program path and a list of argument strings this runner forwards verbatim
/// ahead of the two arguments it appends itself; no line in this program reads
/// one of them, compares it to a literal, or branches on it. That is the same
/// posture the per-slot model plan already takes, and for the same reason: the
/// decision about what to run belongs to the reviewed side, and a control plane
/// that inspected the decision would be a control plane that had an opinion
/// about it.
/// </remarks>
internal sealed record CohortExecution
{
    /// <summary>The one authorization kind a cohort may be declared under.</summary>
    internal const string PreviewOnlyKind = "PreviewOnly";

    internal required int Concurrency { get; init; }

    internal required string StopPolicy { get; init; }

    internal required string AuthorizationKind { get; init; }

    /// <summary>The program each entry's preparation is started as.</summary>
    internal required string CommandPath { get; init; }

    /// <summary>Opaque argument strings forwarded ahead of this runner's own two.</summary>
    internal required IReadOnlyList<string> ArgumentPrefix { get; init; }

    /// <summary>The preparation state each entry is driven to.</summary>
    internal required string Target { get; init; }

    /// <summary>How long one entry's preparation may run before its tree is killed.</summary>
    internal required int EntryTimeoutSeconds { get; init; }

    internal static CohortExecution Read(JsonElement node, string label)
    {
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "concurrency",
            "stopPolicy",
            "authorizationKind",
            "commandPath",
            "argumentPrefix",
            "target",
            "entryTimeoutSeconds");

        // A literal, not a number that happens to be one today. Reading it as a
        // range would make a larger value something this program accepts and then
        // refuses somewhere downstream; a literal makes it a manifest that never
        // loads.
        var concurrency = StrictJson.RequireInt(node, "concurrency", label, 1, 1);
        if (concurrency != CohortManifest.SupportedConcurrency)
        {
            throw new ContractException(
                $"The {label} declares concurrency {concurrency.ToString(CultureInfo.InvariantCulture)}. " +
                "This build runs a cohort strictly sequentially and there is no transition in it that could supervise two entries at once.");
        }

        var stopPolicy = StrictJson.RequireString(node, "stopPolicy", label);
        if (!string.Equals(stopPolicy, CohortManifest.StopPolicyFailFast, StringComparison.Ordinal)
            && !string.Equals(stopPolicy, CohortManifest.StopPolicyContinue, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares stop policy '{stopPolicy}'. The two policies are " +
                $"'{CohortManifest.StopPolicyFailFast}' and '{CohortManifest.StopPolicyContinue}', and neither of them ever " +
                "re-attempts or replaces an entry that ended.");
        }

        var authorizationKind = StrictJson.RequireString(node, "authorizationKind", label);
        if (!string.Equals(authorizationKind, PreviewOnlyKind, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares authorization kind '{authorizationKind}'. This build authorizes exactly one kind, " +
                $"'{PreviewOnlyKind}', and there is no transition it could perform under any other.");
        }

        var prefix = StrictJson.RequireStringArray(node, "argumentPrefix", label);
        if (prefix.Count == 0)
        {
            throw new ContractException($"The {label} field 'argumentPrefix' is empty; the preparation to start is declared rather than guessed.");
        }
        for (var index = 0; index < prefix.Count; index++)
        {
            if (prefix[index].Length == 0)
            {
                throw new ContractException($"The {label} field 'argumentPrefix' holds an empty string at index {index.ToString(CultureInfo.InvariantCulture)}.");
            }
        }

        // Parsed here purely so a manifest naming a state this build does not
        // know is refused before the first entry rather than by the first child.
        var target = StrictJson.RequireString(node, "target", label);
        _ = PreparationStateNames.Parse(target);

        return new CohortExecution
        {
            Concurrency = concurrency,
            StopPolicy = stopPolicy,
            AuthorizationKind = authorizationKind,
            CommandPath = StrictJson.RequireString(node, "commandPath", label),
            ArgumentPrefix = prefix,
            Target = target,
            EntryTimeoutSeconds = StrictJson.RequireInt(node, "entryTimeoutSeconds", label, 1, 86400)
        };
    }

    internal bool StopsOnFirstFailure => string.Equals(StopPolicy, CohortManifest.StopPolicyFailFast, StringComparison.Ordinal);
}

/// <summary>
/// What the whole cohort may consume, whatever its entries turn out to cost.
/// </summary>
/// <remarks>
/// Every ceiling here is global. A per-entry budget already exists and is not
/// this program's to set: it comes from each entry's own signed qualification
/// plan, through the typed request, exactly as it does for a single preparation.
/// What a cohort adds is the question a single preparation cannot ask - how much
/// the SET has consumed so far - and the answer is accumulated from entries that
/// have already ended, never from one in flight.
/// </remarks>
internal sealed record CohortBudgets
{
    internal required int MaximumPullRequests { get; init; }

    internal required int MaximumModelStarts { get; init; }

    internal required int MaximumVerifierAssignments { get; init; }

    internal required int MaximumWallClockSeconds { get; init; }

    /// <summary>Zero, and refused at load if it is anything else.</summary>
    internal required int ProviderWriteBudget { get; init; }

    internal static CohortBudgets Read(JsonElement node, string label)
    {
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "maxPullRequests",
            "maxModelStarts",
            "maxVerifierAssignments",
            "maxWallClockSeconds",
            "providerWriteBudget");

        return new CohortBudgets
        {
            MaximumPullRequests = StrictJson.RequireInt(node, "maxPullRequests", label, 1, 64),
            MaximumModelStarts = StrictJson.RequireInt(node, "maxModelStarts", label, 0, 4096),
            MaximumVerifierAssignments = StrictJson.RequireInt(node, "maxVerifierAssignments", label, 0, 4096),
            MaximumWallClockSeconds = StrictJson.RequireInt(node, "maxWallClockSeconds", label, 1, 604800),
            // A literal zero, for the reason the per-entry delivery budget is a
            // literal zero: there is no permissive value to write, so a cohort
            // asking for a write is not a cohort this program can load.
            ProviderWriteBudget = StrictJson.RequireInt(node, "providerWriteBudget", label, 0, 0)
        };
    }

    internal MapNode Describe() => new MapNode()
        .Set("maxPullRequests", MaximumPullRequests)
        .Set("maxModelStarts", MaximumModelStarts)
        .Set("maxVerifierAssignments", MaximumVerifierAssignments)
        .Set("maxWallClockSeconds", MaximumWallClockSeconds)
        .Set("providerWriteBudget", ProviderWriteBudget);
}

/// <summary>
/// One declared preparation: which subject, under which pins, out of which
/// request file, into which immutable root, at which sealed estimated cost.
/// </summary>
/// <remarks>
/// The entry does not CONFIGURE the preparation. The preparation is configured by
/// its own typed request, which was written in full before the cohort was
/// declared; what the entry carries is a restatement of that request's identity
/// and a digest of its exact bytes, so that the runner can prove, before it
/// starts anything, that the request on disk is the request that was authorized
/// and that it describes the subject the operator thought they were authorizing.
/// A mismatch is a refusal, never a repair.
/// </remarks>
internal sealed record CohortEntry
{
    internal required int Ordinal { get; init; }

    /// <summary>The opaque handle this entry is journalled and reported under.</summary>
    internal required string EntryId { get; init; }

    internal required string RequestPath { get; init; }

    internal required string RequestSha256 { get; init; }

    internal required string OutputRoot { get; init; }

    internal required string Organization { get; init; }

    internal required string Project { get; init; }

    internal required string Repository { get; init; }

    internal required int PullRequestId { get; init; }

    internal required int IterationId { get; init; }

    internal required string SourceCommit { get; init; }

    internal required string CommonCommit { get; init; }

    internal required string TargetCommit { get; init; }

    internal required string ConfigSha256 { get; init; }

    internal required string PromptSha256 { get; init; }

    internal required string SchemaSha256 { get; init; }

    /// <summary>Where the rule bundle this entry was declared against was taken from.</summary>
    internal required string RuleBundleSourceKind { get; init; }

    internal required string RuleBundlePath { get; init; }

    internal required string RuleBundleSha256 { get; init; }

    internal required int EstimatedModelStarts { get; init; }

    internal required int EstimatedVerifierAssignments { get; init; }

    internal required int EstimatedWallClockSeconds { get; init; }

    internal static CohortEntry Read(JsonElement node, string label, int expectedOrdinal)
    {
        if (node.ValueKind != JsonValueKind.Object)
        {
            throw new ContractException($"The {label} is a {StrictJson.Describe(node.ValueKind)}, not an object.");
        }
        StrictJson.RequireNoUnknownFields(
            node,
            label,
            "ordinal",
            "entryId",
            "request",
            "output",
            "subject",
            "digests",
            "ruleBundle",
            "planEstimate");

        // Position and declared ordinal are checked against each other rather
        // than either being inferred. An entries array whose third member calls
        // itself the first would run in an order nobody declared, and the order
        // is the whole of a sequential cohort's meaning.
        var ordinal = StrictJson.RequireInt(node, "ordinal", label, 1, 64);
        if (ordinal != expectedOrdinal)
        {
            throw new ContractException(
                $"The {label} declares ordinal {ordinal.ToString(CultureInfo.InvariantCulture)} at position " +
                $"{expectedOrdinal.ToString(CultureInfo.InvariantCulture)}. A cohort runs the order it declares, so the two agree or the manifest is refused.");
        }

        var entryId = StrictJson.RequireString(node, "entryId", label);
        CohortManifest.RequireOpaqueShape(entryId, label, "entryId", 4, 64);

        var request = StrictJson.RequireObject(node, "request", label);
        StrictJson.RequireNoUnknownFields(request, label + " request", "path", "sha256");

        var output = StrictJson.RequireObject(node, "output", label);
        StrictJson.RequireNoUnknownFields(output, label + " output", "root");

        var subject = StrictJson.RequireObject(node, "subject", label);
        StrictJson.RequireNoUnknownFields(
            subject,
            label + " subject",
            "organization",
            "project",
            "repository",
            "pullRequestId",
            "iterationId",
            "sourceCommit",
            "commonCommit",
            "targetCommit");

        var digests = StrictJson.RequireObject(node, "digests", label);
        StrictJson.RequireNoUnknownFields(digests, label + " digests", "configSha256", "promptSha256", "schemaSha256");

        var ruleBundle = StrictJson.RequireObject(node, "ruleBundle", label);
        StrictJson.RequireNoUnknownFields(ruleBundle, label + " ruleBundle", "sourceKind", "declarationPath", "declarationSha256");

        var estimate = StrictJson.RequireObject(node, "planEstimate", label);
        StrictJson.RequireNoUnknownFields(estimate, label + " planEstimate", "modelStarts", "verifierAssignments", "wallClockSeconds");

        return new CohortEntry
        {
            Ordinal = ordinal,
            EntryId = entryId,
            RequestPath = CohortManifest.RequireRootedPath(StrictJson.RequireString(request, "path", label + " request"), "request path", label),
            RequestSha256 = StrictJson.RequireHex(request, "sha256", label + " request", 64),
            OutputRoot = CohortManifest.RequireRootedPath(StrictJson.RequireString(output, "root", label + " output"), "output root", label),
            Organization = StrictJson.RequireString(subject, "organization", label + " subject"),
            Project = StrictJson.RequireString(subject, "project", label + " subject"),
            Repository = StrictJson.RequireString(subject, "repository", label + " subject"),
            PullRequestId = StrictJson.RequireInt(subject, "pullRequestId", label + " subject", 1, int.MaxValue),
            IterationId = StrictJson.RequireInt(subject, "iterationId", label + " subject", 1, 4096),
            SourceCommit = StrictJson.RequireHex(subject, "sourceCommit", label + " subject", 40),
            CommonCommit = StrictJson.RequireHex(subject, "commonCommit", label + " subject", 40),
            TargetCommit = StrictJson.RequireHex(subject, "targetCommit", label + " subject", 40),
            ConfigSha256 = StrictJson.RequireHex(digests, "configSha256", label + " digests", 64),
            PromptSha256 = StrictJson.RequireHex(digests, "promptSha256", label + " digests", 64),
            SchemaSha256 = StrictJson.RequireHex(digests, "schemaSha256", label + " digests", 64),
            RuleBundleSourceKind = StrictJson.RequireString(ruleBundle, "sourceKind", label + " ruleBundle"),
            RuleBundlePath = CohortManifest.RequireRootedPath(StrictJson.RequireString(ruleBundle, "declarationPath", label + " ruleBundle"), "rule bundle declaration path", label),
            RuleBundleSha256 = StrictJson.RequireHex(ruleBundle, "declarationSha256", label + " ruleBundle", 64),
            EstimatedModelStarts = StrictJson.RequireInt(estimate, "modelStarts", label + " planEstimate", 0, 1024),
            EstimatedVerifierAssignments = StrictJson.RequireInt(estimate, "verifierAssignments", label + " planEstimate", 0, 1024),
            EstimatedWallClockSeconds = StrictJson.RequireInt(estimate, "wallClockSeconds", label + " planEstimate", 1, 86400)
        };
    }

    /// <summary>
    /// The subject binding, digested the way the typed coordinator digests its
    /// own, so the two can be compared without either restating the other's
    /// shape.
    /// </summary>
    internal MapNode DescribeSubject() => new MapNode()
        .Set("organization", Organization)
        .Set("project", Project)
        .Set("repository", Repository)
        .Set("pullRequestId", PullRequestId)
        .Set("iterationId", IterationId)
        .Set("sourceCommit", SourceCommit)
        .Set("commonCommit", CommonCommit)
        .Set("targetCommit", TargetCommit);

    internal string SubjectSha256 => CanonicalJson.Sha256HexOfText(CanonicalJson.Canonical(DescribeSubject()));

    /// <summary>
    /// What the journal and the index record about this entry.
    /// </summary>
    /// <remarks>
    /// By digest, deliberately. The pull request this entry prepares is not
    /// written here, and nor is any other identifying field: what a reader of a
    /// published cohort index gets is a stable opaque handle and a subject digest
    /// they can only match if they already hold the manifest.
    /// </remarks>
    internal MapNode Describe() => new MapNode()
        .Set("ordinal", Ordinal)
        .Set("entryId", EntryId)
        .Set("requestSha256", RequestSha256)
        .Set("subjectSha256", SubjectSha256)
        .Set("ruleBundleSourceKind", RuleBundleSourceKind)
        .Set("ruleBundleSha256", RuleBundleSha256)
        .Set("estimatedModelStarts", EstimatedModelStarts)
        .Set("estimatedVerifierAssignments", EstimatedVerifierAssignments)
        .Set("estimatedWallClockSeconds", EstimatedWallClockSeconds);
}
