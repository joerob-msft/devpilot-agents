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
    internal const string ContractVersionValue = "devpilot.shadow-cohort.manifest.v3";

    /// <summary>
    /// The contracts this one replaced, each named so that a manifest written
    /// against one is refused with the reason it is refused for rather than with
    /// a generic mismatch.
    /// </summary>
    /// <remarks>
    /// v1's model-start budget was measured in reviewer processes; v2 fixed that
    /// and left the verifier ceiling measured in committed terminal transitions,
    /// which capped at eight and in practice read four for an entry that stood on
    /// forty assignments. Neither is silently rescored: an operator re-declares
    /// the cohort against a sealed bound in the unit this build spends.
    /// </remarks>
    internal const string UnsafeBudgetContractVersion = "devpilot.shadow-cohort.manifest.v1";

    /// <summary>The contract whose verifier ceiling was declared in the wrong unit.</summary>
    internal const string UnsafeVerifierBudgetContractVersion = "devpilot.shadow-cohort.manifest.v2";

    internal const string KindValue = "shadow-cohort-run";

    /// <summary>
    /// The one other kind a cohort may declare, under which the fault-injection
    /// arguments a fault test needs are permitted.
    /// </summary>
    /// <remarks>
    /// A fault test has to be able to stop a preparation in the middle, and the
    /// only way to do that is to pass the argument that stops it. An operator
    /// cohort must never pass that argument, because a preparation halted before
    /// its target is a preparation whose evidence is partial and whose exit code
    /// says so - which is exactly the shape a completed entry would otherwise be
    /// mistaken for.
    ///
    /// So the permission is a KIND rather than a flag, and the kind carries a
    /// price: a cohort declaring it may not start the shipping preparation. It
    /// must start a stub instead, and the stub is what is proved - the command
    /// and its arguments may not name this program, and they must name a script.
    /// A cohort that cannot reach the preparation cannot reach the reviewer the
    /// preparation launches. That is the whole of the claim, and it is a property
    /// of the launch rather than a promise in a field: a stub script is free to
    /// start whatever IT likes, so this is a development affordance rather than a
    /// proof of model isolation, and it is never an operator contract.
    /// </remarks>
    internal const string TestOnlyKindValue = "shadow-cohort-test-run";

    /// <summary>This program, by file name, in both shapes it is started as.</summary>
    internal static readonly string[] ShippingPreparationFileNames =
    [
        "ShadowRunCoordinator.dll",
        "ShadowRunCoordinator.exe"
    ];

    /// <summary>
    /// The framework host, by whole file name, in the two shapes it is named as.
    /// </summary>
    /// <remarks>
    /// Whole names rather than a name-without-extension test, because the latter
    /// admits <c>dotnet.com</c>, <c>dotnet.cmd</c> and <c>dotnet.scr</c> - none of
    /// which is the host, all of which are launchable, and one of which Windows
    /// would prefer over the real host on a bare <c>dotnet</c> lookup.
    /// </remarks>
    internal static readonly string[] DotnetHostFileNames =
    [
        "dotnet",
        "dotnet.exe"
    ];


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

    /// <summary>Which of the two kinds this cohort was declared under.</summary>
    internal required string Kind { get; init; }

    /// <summary>Whether this cohort may carry fault-injection arguments.</summary>
    internal bool IsTestOnly => string.Equals(Kind, TestOnlyKindValue, StringComparison.Ordinal);

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

        // A v1 manifest declared a model-start estimate with nothing behind it,
        // and the runner it was written for counted reviewer processes rather
        // than model starts. Re-reading one under this build would silently
        // reinterpret both halves of its budget, so it is refused by name and the
        // operator re-declares it with a sealed bound.
        if (root.TryGetProperty("contractVersion", out var version)
            && version.ValueKind == JsonValueKind.String
            && string.Equals(version.GetString(), UnsafeBudgetContractVersion, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares contract '{UnsafeBudgetContractVersion}', whose model-start budget was measured in reviewer processes " +
                "rather than in real model subprocess starts and carried no proof that its estimate was an upper bound. This build does not " +
                $"reinterpret it: re-declare the cohort as '{ContractVersionValue}' with a sealed model-start bound per entry.");
        }
        // A v2 manifest declared its verifier ceiling in a unit that could not
        // count above eight: the runner it was written for derived the figure
        // from committed terminal transitions, so an entry that stood on forty
        // cross-verifier assignments was recorded as having stood on four. Its
        // ceiling would be silently rescored into a unit forty times larger, so
        // it is refused by name too.
        if (root.TryGetProperty("contractVersion", out var priorVersion)
            && priorVersion.ValueKind == JsonValueKind.String
            && string.Equals(priorVersion.GetString(), UnsafeVerifierBudgetContractVersion, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares contract '{UnsafeVerifierBudgetContractVersion}', whose verifier-assignment budget was measured in committed " +
                "terminal transitions rather than in real candidate-by-model assignments, so it could not count above eight however many " +
                "assignments an entry really stood on. This build does not reinterpret it: re-declare the cohort as " +
                $"'{ContractVersionValue}', whose per-entry sealed bound publishes a verifier-assignment maximum in the unit this build spends.");
        }
        StrictJson.RequireLiteral(root, "contractVersion", ContractVersionValue, label);
        var kind = StrictJson.RequireString(root, "kind", label);
        if (!string.Equals(kind, KindValue, StringComparison.Ordinal)
            && !string.Equals(kind, TestOnlyKindValue, StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares kind '{kind}'. This build runs '{KindValue}' and, for fault tests that may not name the " +
                $"shipping reviewer, '{TestOnlyKindValue}'.");
        }

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
            Kind = kind,
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
        // Through the one guarded reader, so a manifest or a bundle that is
        // locked, vanished or unreadable is a refusal naming the file rather
        // than a filesystem fault raised where a cohort was owed an answer.
        var bytes = StrictJson.ReadFileBytes(path, label, 8L * 1024 * 1024);
        if (bytes.Length == 0)
        {
            throw new ContractException($"The {label} file '{path}' is empty; a partial write must not read as an empty result.");
        }
        return bytes;
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
        try
        {
            return Path.GetFullPath(path);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            // Fully qualified is not the same as resolvable. A path holding a NUL
            // is fully qualified by inspection and throws here, and so does one too
            // long for the platform to name. Both are manifests this build refuses
            // to read, and a refusal is the typed contract exception with the field
            // in it - not a fault from underneath with a stack trace on it, which
            // is not one of the exit codes this program documents.
            throw new ContractException(
                $"The {label} declares a {field} '{path}' that cannot be resolved to an absolute path: {error.Message}");
        }
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

    /// <summary>
    /// The tokens in <see cref="ArgumentPrefix"/> a production cohort may not
    /// pass, each with the reason it was refused.
    /// </summary>
    /// <remarks>
    /// Computed at load and enforced at launch rather than at load, because
    /// rebuilding an index launches nothing: a frozen root written by an earlier
    /// build has to stay readable so its evidence can be re-derived, and refusing
    /// to parse its manifest would make the evidence unreachable rather than
    /// unusable. What must never happen again is a LAUNCH under these arguments.
    /// </remarks>
    internal required IReadOnlyList<string> RefusedArguments { get; init; }

    /// <summary>
    /// Whether the command and its arguments name this program, which is the
    /// thing that can start a reviewer and therefore a model.
    /// </summary>
    internal required bool NamesShippingPreparation { get; init; }

    /// <summary>
    /// Whether the command or its arguments name a script, which is the shape a
    /// stub adapter takes.
    /// </summary>
    internal required bool NamesStubAdapter { get; init; }

    /// <summary>
    /// Whether the launch is one of the two enumerated shapes that start this
    /// program directly, with nothing between the manifest's arguments and this
    /// program's own parser.
    /// </summary>
    internal required bool IsShippingLaunchProfile { get; init; }

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
            RequireNoControlCharacter(
                prefix[index],
                $"{label} field 'argumentPrefix' at index {index.ToString(CultureInfo.InvariantCulture)}");
        }

        // Parsed here purely so a manifest naming a state this build does not
        // know is refused before the first entry rather than by the first child.
        var target = StrictJson.RequireString(node, "target", label);
        _ = PreparationStateNames.Parse(target);

        var commandPath = StrictJson.RequireString(node, "commandPath", label);
        RequireNoControlCharacter(commandPath, $"{label} field 'commandPath'");
        var namesPreparation = NamesShipping(commandPath);
        var namesStub = NamesScript(commandPath);
        for (var index = 0; index < prefix.Count; index++)
        {
            namesPreparation |= NamesShipping(prefix[index]);
            namesStub |= NamesScript(prefix[index]);
        }

        return new CohortExecution
        {
            Concurrency = concurrency,
            StopPolicy = stopPolicy,
            AuthorizationKind = authorizationKind,
            CommandPath = commandPath,
            ArgumentPrefix = prefix,
            RefusedArguments = ClassifyArguments(prefix),
            NamesShippingPreparation = namesPreparation,
            NamesStubAdapter = namesStub,
            IsShippingLaunchProfile = IsShippingProfile(commandPath, prefix),
            Target = target,
            EntryTimeoutSeconds = StrictJson.RequireInt(node, "entryTimeoutSeconds", label, 1, 86400)
        };
    }

    /// <summary>
    /// Refuses a launch token holding a character no path or argument has any use
    /// for.
    /// </summary>
    /// <remarks>
    /// A well-formedness refusal, and it exists because of exactly one character.
    /// <c>Path.GetFileName</c> scans back from the END of a string to the last
    /// separator; the Win32 process creation this token eventually reaches is
    /// handed a null-terminated buffer and stops at the FIRST U+0000. So a token
    /// such as <c>C:\windows\system32\whoami.exe\0\ShadowRunCoordinator.dll</c>
    /// answers "yes, that names the shipping preparation" to every string test in
    /// this file while starting something else entirely: the two functions read
    /// opposite ends of the same string. No enumeration of launch shapes can hold
    /// while that is true, because the shape being enumerated is not the shape
    /// being run.
    ///
    /// The whole C0 range and DEL go, not U+0000 alone. None of them can appear in
    /// a Windows path or in an argument this program parses, so refusing the range
    /// costs nothing and leaves no second character to be clever with. It is a
    /// load-time refusal, alongside the empty-token one above, because a token
    /// that cannot be read the same way twice is malformed rather than merely
    /// inadmissible - and no manifest that a real cohort ever wrote can contain
    /// one, so nothing already on disk becomes unreadable.
    /// </remarks>
    private static void RequireNoControlCharacter(string token, string label)
    {
        for (var index = 0; index < token.Length; index++)
        {
            var character = token[index];
            if (character >= ' ' && character != '\u007f')
            {
                continue;
            }
            throw new ContractException(
                $"The {label} holds the control character U+{((int)character).ToString("X4", CultureInfo.InvariantCulture)} at " +
                $"index {index.ToString(CultureInfo.InvariantCulture)}. A launch token is read here as text and executed elsewhere " +
                "as a null-terminated buffer; a token those two readings disagree about names one program to this build and starts " +
                "another, so it is refused rather than interpreted.");
        }
    }

    /// <summary>Whether one token names a script this program never launches in production.</summary>
    private static bool NamesScript(string token)
    {
        string extension;
        try
        {
            extension = Path.GetExtension(token);
        }
        catch (ArgumentException)
        {
            return false;
        }
        return extension.Length > 0 && StubAdapterExtensions.Contains(extension);
    }

    /// <summary>
    /// Whether this launch is one of the two shapes that provably start this
    /// program and nothing else.
    /// </summary>
    /// <remarks>
    /// The question a production cohort has to answer is not "are these arguments
    /// acceptable" but "does this launch reach a parser that will hold them to
    /// that". Classifying the arguments alone answers the first and leaves the
    /// second open: a cohort naming a shell can put every refused switch inside a
    /// single token that is not an option and has no extension - <c>cmd /c "dotnet
    /// ...\ShadowRunCoordinator.dll --halt-after deliveryTerminalVerified"</c> -
    /// and the splitting that reintroduces them happens one process later, where
    /// nothing here can see it.
    ///
    /// So the admissible launches are enumerated rather than filtered. Either the
    /// command is this program, or the command is the dotnet host and the FIRST
    /// argument is this program's assembly: in both, the very next thing to read
    /// an argument is the preparation's own parser, which takes whole tokens and
    /// knows no <c>--option=value</c> form. Anything else - a shell, a wrapper, a
    /// script, this program named somewhere other than first - is refused without
    /// asking what its arguments were.
    /// </remarks>
    private static bool IsShippingProfile(string commandPath, IReadOnlyList<string> prefix)
    {
        if (NamesShipping(commandPath))
        {
            return true;
        }

        string command;
        try
        {
            command = Path.GetFileName(commandPath);
        }
        catch (ArgumentException)
        {
            return false;
        }
        var namesHost = false;
        foreach (var candidate in CohortManifest.DotnetHostFileNames)
        {
            namesHost |= string.Equals(command, candidate, StringComparison.OrdinalIgnoreCase);
        }
        if (!namesHost)
        {
            return false;
        }
        return prefix.Count > 0 && NamesShipping(prefix[0]);
    }

    /// <summary>Whether one token names this program by file name.</summary>
    private static bool NamesShipping(string token)
    {
        string name;
        try
        {
            name = Path.GetFileName(token);
        }
        catch (ArgumentException)
        {
            // A token that is not a path shape cannot be naming a file, and a
            // question about a file name is answered 'no' rather than thrown.
            return false;
        }
        foreach (var candidate in CohortManifest.ShippingPreparationFileNames)
        {
            if (string.Equals(name, candidate, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Every argument a production cohort may not forward to a preparation, and
    /// the reason each one is refused.
    /// </summary>
    /// <remarks>
    /// Whole tokens, compared as whole tokens. A substring test would refuse an
    /// output root that happened to contain the word "fault" and would miss
    /// nothing in exchange, because an argument list is already split: there is
    /// no assembling to see through. The one shape that hides an option inside a
    /// single token is <c>--option=value</c>, so the part before the first '=' is
    /// compared as well as the whole.
    ///
    /// The comparison is case-insensitive even though the preparation's own parse
    /// is ordinal. That is deliberate and is not a mistake about the parser: a
    /// token this method let through in the wrong case would be refused by the
    /// preparation as unrecognised, so refusing it here costs nothing, and being
    /// stricter than the thing being guarded is the right direction for a guard.
    /// </remarks>
    private static IReadOnlyList<string> ClassifyArguments(IReadOnlyList<string> prefix)
    {
        var refused = new List<string>();
        for (var index = 0; index < prefix.Count; index++)
        {
            var token = prefix[index];
            var separator = token.IndexOf('=', StringComparison.Ordinal);
            var option = separator < 0 ? token : token[..separator];

            if (FaultInjectionOptions.Contains(option))
            {
                refused.Add($"'{token}' injects a fault or stops a preparation short of its target");
                continue;
            }
            if (RunnerOwnedOptions.Contains(option))
            {
                refused.Add($"'{token}' is an argument this runner appends itself, and a second one would redirect the child");
                continue;
            }
            if (ScriptHostOptions.Contains(option))
            {
                refused.Add($"'{token}' runs a script rather than the declared preparation");
                continue;
            }
            var extension = Path.GetExtension(token);
            if (extension.Length > 0 && StubAdapterExtensions.Contains(extension))
            {
                refused.Add($"'{token}' is a script, and a cohort that prepares live pull requests runs the compiled preparation");
            }
        }
        return refused;
    }

    /// <summary>Arguments whose whole purpose is to make a preparation misbehave.</summary>
    private static readonly HashSet<string> FaultInjectionOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "--halt-after",
        "--halt",
        "--halt-at",
        "--stop-after",
        "--fault",
        "--faults",
        "--inject-fault",
        "--fault-after",
        "--simulate",
        "--simulate-fault",
        "--crash",
        "--crash-after",
        "--fail-after",
        "--abort-after",
        "--exit-code",
        "--force-exit",
        "--stub",
        "--stub-adapter",
        "--test-only",
        "--test-hook",
        "--test-mode",
        "--debug-hook",
        "--debug-break"
    };

    /// <summary>Arguments this runner appends itself, so a manifest may not.</summary>
    private static readonly HashSet<string> RunnerOwnedOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "--request",
        "--target",
        "--cohort",
        "--authorized-by",
        "--rebuild-index"
    };

    /// <summary>Ways of asking a shell to run something other than the preparation.</summary>
    private static readonly HashSet<string> ScriptHostOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "-File",
        "-Command",
        "-c",
        "-EncodedCommand",
        "-e"
    };

    /// <summary>Extensions a stub adapter is written in.</summary>
    private static readonly HashSet<string> StubAdapterExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".ps1",
        ".psm1",
        ".cmd",
        ".bat",
        ".sh",
        ".py",
        ".js"
    };

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

    /// <summary>
    /// The ceiling on real cross-verifier assignments - one candidate paired
    /// with one required reciprocal model - across the whole cohort. Two slots
    /// whose plans admit 128 assignments each bound at 256, so the range here is
    /// sized for that unit rather than for the eight terminal transitions the
    /// figure used to be derived from.
    /// </summary>
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
            MaximumModelStarts = StrictJson.RequireInt(node, "maxModelStarts", label, 0, 65536),
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

    /// <summary>
    /// The branch this pull request merges into, as the provider names it, or
    /// empty when the manifest did not pin one.
    /// </summary>
    /// <remarks>
    /// Optional at load and required at launch. A frozen root written before this
    /// field existed still has to be readable, or its evidence would become
    /// unreachable; but an entry about to start a preparation has to be able to
    /// prove that the configuration it is about to run under is the configuration
    /// for the branch this pull request actually targets. Absent, therefore, is
    /// not "any target" - it is "not yet proven", which blocks the launch.
    /// </remarks>
    internal required string TargetRefName { get; init; }

    internal required string ConfigSha256 { get; init; }

    internal required string PromptSha256 { get; init; }

    internal required string SchemaSha256 { get; init; }

    /// <summary>Where the rule bundle this entry was declared against was taken from.</summary>
    internal required string RuleBundleSourceKind { get; init; }

    internal required string RuleBundlePath { get; init; }

    internal required string RuleBundleSha256 { get; init; }

    internal required int EstimatedModelStarts { get; init; }

    /// <summary>
    /// The sealed artifact that proves the model-start estimate is an upper
    /// bound, and not a figure copied from what a quiet run happened to cost.
    /// </summary>
    /// <remarks>
    /// Derived on the reviewed side by tools/New-ShadowModelStartBound.ps1, which
    /// owns what a reviewer argument vector means. This build verifies the
    /// artifact's digest, verifies it was taken over the same sealed request this
    /// entry pins, and requires the declared estimate to be at least the bound it
    /// publishes. It never reads a model name and never re-derives the bound.
    /// </remarks>
    internal required string ModelStartBoundPath { get; init; }

    internal required string ModelStartBoundSha256 { get; init; }

    /// <summary>
    /// The cross-verifier assignments this entry's sealed plan may hand out -
    /// one candidate paired with one required reciprocal model, summed across
    /// its declared slots. Proved against the same sealed bound artifact the
    /// model-start estimate is proved against, and ranged for that unit: two
    /// slots capped at 128 assignments each estimate 256.
    /// </summary>
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
            "targetCommit",
            "targetRefName");

        var digests = StrictJson.RequireObject(node, "digests", label);
        StrictJson.RequireNoUnknownFields(digests, label + " digests", "configSha256", "promptSha256", "schemaSha256");

        var ruleBundle = StrictJson.RequireObject(node, "ruleBundle", label);
        StrictJson.RequireNoUnknownFields(ruleBundle, label + " ruleBundle", "sourceKind", "declarationPath", "declarationSha256");

        var estimate = StrictJson.RequireObject(node, "planEstimate", label);
        StrictJson.RequireNoUnknownFields(estimate, label + " planEstimate", "modelStarts", "verifierAssignments", "wallClockSeconds", "modelStartBound");
        var bound = StrictJson.RequireObject(estimate, "modelStartBound", label + " planEstimate");
        StrictJson.RequireNoUnknownFields(bound, label + " planEstimate modelStartBound", "path", "sha256");

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
            TargetRefName = ReadOptionalTargetRefName(subject, label + " subject"),
            ConfigSha256 = StrictJson.RequireHex(digests, "configSha256", label + " digests", 64),
            PromptSha256 = StrictJson.RequireHex(digests, "promptSha256", label + " digests", 64),
            SchemaSha256 = StrictJson.RequireHex(digests, "schemaSha256", label + " digests", 64),
            RuleBundleSourceKind = StrictJson.RequireString(ruleBundle, "sourceKind", label + " ruleBundle"),
            RuleBundlePath = CohortManifest.RequireRootedPath(StrictJson.RequireString(ruleBundle, "declarationPath", label + " ruleBundle"), "rule bundle declaration path", label),
            RuleBundleSha256 = StrictJson.RequireHex(ruleBundle, "declarationSha256", label + " ruleBundle", 64),
            EstimatedModelStarts = StrictJson.RequireInt(estimate, "modelStarts", label + " planEstimate", 0, 8192),
            ModelStartBoundPath = CohortManifest.RequireRootedPath(StrictJson.RequireString(bound, "path", label + " planEstimate modelStartBound"), "model start bound path", label),
            ModelStartBoundSha256 = StrictJson.RequireHex(bound, "sha256", label + " planEstimate modelStartBound", 64),
            EstimatedVerifierAssignments = StrictJson.RequireInt(estimate, "verifierAssignments", label + " planEstimate", 0, 4096),
            EstimatedWallClockSeconds = StrictJson.RequireInt(estimate, "wallClockSeconds", label + " planEstimate", 1, 86400)
        };
    }

    /// <summary>
    /// Reads the optional pinned target ref, refusing a present-but-malformed one
    /// rather than treating it as absent.
    /// </summary>
    private static string ReadOptionalTargetRefName(JsonElement subject, string label)
    {
        if (!subject.TryGetProperty("targetRefName", out _))
        {
            return string.Empty;
        }
        var text = StrictJson.RequireString(subject, "targetRefName", label);
        if (!text.StartsWith("refs/", StringComparison.Ordinal))
        {
            throw new ContractException(
                $"The {label} declares targetRefName '{text}'. A pinned target is compared with the reviewer configuration's own " +
                "validated ref, which is fully qualified, so a short name would compare unequal to the branch it names.");
        }
        if (text.Length > 512)
        {
            throw new ContractException($"The {label} declares a targetRefName of {text.Length.ToString(CultureInfo.InvariantCulture)} characters.");
        }
        return text;
    }

    /// <summary>
    /// The subject binding, digested the way the typed coordinator digests its
    /// own, so the two can be compared without either restating the other's
    /// shape.
    /// </summary>
    /// <remarks>
    /// <see cref="TargetRefName"/> is deliberately absent. The typed request has
    /// no such field, so digesting it here would make every manifest subject
    /// compare unequal to the request it pins - and would silently change the
    /// digest of every subject already recorded in a frozen root. The pinned ref
    /// is checked against the reviewer configuration instead, which is where the
    /// mismatch it exists to catch actually lives.
    /// </remarks>
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
        .Set("modelStartBoundSha256", ModelStartBoundSha256)
        .Set("estimatedVerifierAssignments", EstimatedVerifierAssignments)
        .Set("estimatedWallClockSeconds", EstimatedWallClockSeconds);
}
