using System.Globalization;

namespace DevPilot.ShadowRunCoordinator;

/// <summary>
/// The entry point for one shadow preparation.
/// </summary>
/// <remarks>
/// Standard output carries progress for a human and nothing else. Every contract
/// this program produces is a file at a path the caller named, so a caller never
/// has to parse this program's chatter, and a stray diagnostic line can never
/// become part of a contract.
///
/// Exit codes are the only machine-readable thing on the console, and they
/// separate the failures that mean different things: a malformed request is not
/// the same event as a busy output root, which is not the same event as a child
/// that failed, which is not the same event as an edited state file.
/// </remarks>
internal static class Program
{
    private const int ExitOk = CoordinatorExitCodes.Ok;
    private const int ExitUsage = CoordinatorExitCodes.Usage;
    private const int ExitContract = CoordinatorExitCodes.Contract;
    private const int ExitLeaseConflict = CoordinatorExitCodes.LeaseConflict;
    private const int ExitChildFailure = CoordinatorExitCodes.ChildFailure;
    /// <summary>A supervised slot reached a terminal that was not 'complete'. Not a coordinator fault.</summary>
    private const int ExitSlotNotComplete = CoordinatorExitCodes.SlotNotComplete;
    /// <summary>A previous run's launch was never accounted for, so this one refuses to guess.</summary>
    private const int ExitUnresolvedLaunch = CoordinatorExitCodes.UnresolvedLaunch;
    private const int ExitHalted = CoordinatorExitCodes.Halted;

    internal static int Main(string[] args)
    {
        string? requestPath = null;
        string? targetName = null;
        string? haltAfterName = null;
        string? cohortPath = null;
        string? operatorAlias = null;
        string? registryPath = null;
        string? candidatesPath = null;
        string? selectCount = null;
        string? selectionOutPath = null;
        var fromCohorts = new List<string>();
        var rebuildRegistry = false;
        var selectSubjects = false;
        var acceptUnresolvedDefects = false;
        var acceptUnstartedRegistry = false;
        var retractClearedHolds = false;
        var rebuildIndex = false;
        string? atomicPublishSelfTestRoot = null;

        // The parse runs inside the same guard as the rest of the entry point.
        // A missing option value is a usage fault, and a usage fault that escapes
        // as an unhandled exception would print a stack trace and exit with a
        // code outside the documented set, in a tool whose whole premise is that
        // the exit code is the only machine-readable thing on the console.
        try
        {
            for (var index = 0; index < args.Length; index++)
            {
                switch (args[index])
                {
                    case "--request":
                        requestPath = Next(args, ref index, "--request");
                        break;
                    case "--target":
                        targetName = Next(args, ref index, "--target");
                        break;
                    case "--halt-after":
                        haltAfterName = Next(args, ref index, "--halt-after");
                        break;
                    case "--cohort":
                        cohortPath = Next(args, ref index, "--cohort");
                        break;
                    case "--authorized-by":
                        operatorAlias = Next(args, ref index, "--authorized-by");
                        break;
                    case "--rebuild-index":
                        rebuildIndex = true;
                        break;
                    case "--rebuild-registry":
                        rebuildRegistry = true;
                        break;
                    case "--select-subjects":
                        selectSubjects = true;
                        break;
                    case "--candidates":
                        candidatesPath = Next(args, ref index, "--candidates");
                        break;
                    case "--select-count":
                        selectCount = Next(args, ref index, "--select-count");
                        break;
                    case "--accept-unresolved-defects":
                        acceptUnresolvedDefects = true;
                        break;
                    case "--accept-unstarted-registry":
                        acceptUnstartedRegistry = true;
                        break;
                    case "--retract-cleared-holds":
                        retractClearedHolds = true;
                        break;
                    case "--out":
                        selectionOutPath = Next(args, ref index, "--out");
                        break;
                    case "--registry":
                        registryPath = Next(args, ref index, "--registry");
                        break;
                    case "--from-cohort":
                        fromCohorts.Add(Next(args, ref index, "--from-cohort"));
                        break;
                    case "--selftest-atomic-publish":
                        atomicPublishSelfTestRoot = Next(args, ref index, "--selftest-atomic-publish");
                        break;
                    case "--help":
                        Console.Out.WriteLine(Usage);
                        return ExitOk;
                    default:
                        Console.Error.WriteLine($"Unrecognised argument '{args[index]}'.");
                        Console.Error.WriteLine(Usage);
                        return ExitUsage;
                }
            }

            if (atomicPublishSelfTestRoot is not null)
            {
                // A diagnostic mode, and deliberately an exclusive one: it writes
                // only under the scratch root it is given, starts no cohort, and
                // touches no request, so combining it with a real mode could only
                // ever mean the caller wanted two different jobs at once.
                if (requestPath is not null || cohortPath is not null || registryPath is not null
                    || rebuildRegistry || rebuildIndex || selectSubjects)
                {
                    Console.Error.WriteLine("--selftest-atomic-publish runs the atomic state publish checks and starts nothing; it does not combine with the other modes.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                return AtomicPublishSelfTest.Run(atomicPublishSelfTestRoot, Console.Out);
            }

            if (selectSubjects)
            {
                if (rebuildRegistry || cohortPath is not null || requestPath is not null || rebuildIndex)
                {
                    Console.Error.WriteLine("--select-subjects chooses subjects and starts nothing; it does not combine with the other modes.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                if (registryPath is null || candidatesPath is null || selectionOutPath is null)
                {
                    Console.Error.WriteLine("--select-subjects needs --registry <path>, --candidates <path> and --out <path>.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                if (!int.TryParse(selectCount ?? "1", NumberStyles.None, CultureInfo.InvariantCulture, out var count)
                    || count < 1
                    || count > 64)
                {
                    Console.Error.WriteLine("--select-count takes a whole number between 1 and 64.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                return CohortSubjectSelection.Run(
                    registryPath,
                    candidatesPath,
                    count,
                    selectionOutPath,
                    acceptUnresolvedDefects,
                    acceptUnstartedRegistry,
                    Console.Out);
            }

            if (rebuildRegistry)
            {
                // A rebuild is its own mode. It reads immutable cohort roots the
                // caller names and writes one registry; it never runs a cohort, so
                // pairing it with --cohort would be asking for two different jobs
                // in one invocation and is refused rather than ordered arbitrarily.
                if (cohortPath is not null)
                {
                    Console.Error.WriteLine("--rebuild-registry rebuilds an account from finished cohort roots and does not run one; drop --cohort.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                if (registryPath is null)
                {
                    Console.Error.WriteLine("--rebuild-registry needs --registry <path> to say which account is being rebuilt.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                if (fromCohorts.Count == 0)
                {
                    Console.Error.WriteLine("--rebuild-registry needs at least one --from-cohort <manifest path>. It reports what roots hold; it does not search for them.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                if (requestPath is not null || targetName is not null || haltAfterName is not null || rebuildIndex)
                {
                    Console.Error.WriteLine("--rebuild-registry takes only --registry, --from-cohort, --retract-cleared-holds and --authorized-by.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
                }
                return RebuildRegistry(registryPath, fromCohorts, operatorAlias, retractClearedHolds);
            }

            if (registryPath is not null || fromCohorts.Count > 0)
            {
                Console.Error.WriteLine("--registry and --from-cohort belong to --rebuild-registry.");
                Console.Error.WriteLine(Usage);
                return ExitUsage;
            }
            if (retractClearedHolds)
            {
                Console.Error.WriteLine("--retract-cleared-holds belongs to --rebuild-registry.");
                Console.Error.WriteLine(Usage);
                return ExitUsage;
            }
            if (candidatesPath is not null || selectCount is not null || selectionOutPath is not null || acceptUnresolvedDefects || acceptUnstartedRegistry)
            {
                Console.Error.WriteLine(
                    "--candidates, --select-count, --out, --accept-unresolved-defects and --accept-unstarted-registry belong to --select-subjects.");
                Console.Error.WriteLine(Usage);
                return ExitUsage;
            }

            if (cohortPath is not null)
            {
                return RunCohort(cohortPath, operatorAlias, rebuildIndex, requestPath, targetName, haltAfterName);
            }
            if (rebuildIndex)
            {
                Console.Error.WriteLine("--rebuild-index applies to a cohort and needs --cohort.");
                Console.Error.WriteLine(Usage);
                return ExitUsage;
            }
            if (operatorAlias is not null)
            {
                Console.Error.WriteLine("--authorized-by applies to a cohort and needs --cohort.");
                Console.Error.WriteLine(Usage);
                return ExitUsage;
            }

            if (requestPath is null)
            {
                Console.Error.WriteLine("A --request path is required.");
                Console.Error.WriteLine(Usage);
                return ExitUsage;
            }

            var request = CoordinatorRequest.Load(requestPath);
            var target = targetName is null ? PreparationState.RunSetReady : PreparationStateNames.Parse(targetName);
            var haltAfter = haltAfterName is null ? (PreparationState?)null : PreparationStateNames.Parse(haltAfterName);
            // Compared by rank, not by enum value. The three terminal outcomes
            // share a rank, so a halt at slot1TerminalFailed inside a target of
            // slot1TerminalVerified is the same boundary rather than a step past
            // it - and an ordinal comparison would call it out of range.
            if (haltAfter is { } halt && PreparationStateNames.RankOf(halt) > PreparationStateNames.RankOf(target))
            {
                throw new ContractException($"--halt-after '{PreparationStateNames.ToName(halt)}' is beyond --target '{PreparationStateNames.ToName(target)}'.");
            }
            // Naming a slot state as the target is a request to launch, so it is
            // refused unless the request carries an explicit authorization. The
            // default remains what it was: prepare, and launch nothing.
            if (PreparationStateNames.IsSlotState(target))
            {
                request.RequireSlotSet();
            }
            return Run(request, target, haltAfter);
        }
        catch (ContractException error)
        {
            Console.Error.WriteLine(error.Message);
            return ExitContract;
        }
        catch (LeaseConflictException error)
        {
            Console.Error.WriteLine(error.Message);
            return ExitLeaseConflict;
        }
        catch (UnresolvedLaunchException error)
        {
            // Deliberately its own code. An unaccounted-for launch is neither a
            // bad request nor a child that failed: it is this coordinator
            // declining to relaunch something it cannot prove is not already
            // running, and an operator has to be able to tell those apart.
            Console.Error.WriteLine(error.Message);
            return ExitUnresolvedLaunch;
        }
        catch (CohortUnresolvedLaunchException error)
        {
            // The same event one level up: a cohort that committed the intent to
            // start an entry and cannot prove that entry is not still running.
            Console.Error.WriteLine(error.Message);
            return ExitUnresolvedLaunch;
        }
        catch (CohortBlockedException error)
        {
            // Its own code because it is not a stop policy outcome. Something was
            // observed that stops the WHOLE set regardless of policy, and an
            // operator must not read it as 'one entry failed'.
            Console.Error.WriteLine(error.Message);
            return CoordinatorExitCodes.CohortBlocked;
        }
        catch (ChildFailureException error)
        {
            Console.Error.WriteLine(error.Message);
            return ExitChildFailure;
        }
    }

    /// <summary>
    /// The cohort entry mode: operator-initiated, one manifest, one entry at a
    /// time.
    /// </summary>
    /// <remarks>
    /// The alias is required rather than defaulted, and it is required on the
    /// COMMAND LINE rather than read out of the manifest. A manifest is a file,
    /// and a file can be left somewhere a timer finds it; requiring the
    /// authorization at the point of invocation is what keeps this an
    /// operator-initiated action rather than a scheduled one. Nothing here checks
    /// who the operator is - that is not a claim this program is in a position to
    /// make - it records the claim the invoker made, so the account names someone.
    /// </remarks>
    private static int RunCohort(
        string cohortPath,
        string? operatorAlias,
        bool rebuildIndex,
        string? requestPath,
        string? targetName,
        string? haltAfterName)
    {
        if (requestPath is not null || targetName is not null || haltAfterName is not null)
        {
            Console.Error.WriteLine("--cohort runs a declared set and takes its request, target and halt points from the manifest.");
            Console.Error.WriteLine(Usage);
            return ExitUsage;
        }
        if (operatorAlias is null)
        {
            Console.Error.WriteLine("--cohort requires --authorized-by <alias>: a cohort is started by an operator, never by a timer.");
            Console.Error.WriteLine(Usage);
            return ExitUsage;
        }
        CohortManifest.RequireOpaqueShape(operatorAlias, "cohort invocation", "--authorized-by", 3, 64);
        var manifest = CohortManifest.Load(cohortPath);
        return CohortRunner.Run(manifest, operatorAlias, rebuildIndex, Console.Out);
    }

    /// <summary>
    /// The rebuild mode: read finished cohort roots, write one account, start
    /// nothing.
    /// </summary>
    /// <remarks>
    /// The alias is required here for the same reason it is required to run a
    /// cohort. A rebuilt account is what a later run refuses against, so the file
    /// records who produced it. Nothing about the rebuild is unattended: it names
    /// its roots explicitly and never searches for them, because an account
    /// assembled from whatever happened to be on a disk is not an account anyone
    /// can defend.
    /// </remarks>
    private static int RebuildRegistry(
        string registryPath,
        IReadOnlyList<string> manifestPaths,
        string? operatorAlias,
        bool retractClearedHolds)
    {
        if (operatorAlias is null)
        {
            Console.Error.WriteLine("--rebuild-registry requires --authorized-by <alias>: an account records who assembled it.");
            Console.Error.WriteLine(Usage);
            return ExitUsage;
        }
        CohortManifest.RequireOpaqueShape(operatorAlias, "registry rebuild", "--authorized-by", 3, 64);
        return CohortRegistryRebuild.Run(registryPath, manifestPaths, operatorAlias, retractClearedHolds, Console.Out);
    }

    private static int Run(CoordinatorRequest request, PreparationState target, PreparationState? haltAfter)
    {
        Directory.CreateDirectory(request.OutputRoot);
        Directory.CreateDirectory(request.CoordinatorRoot);

        // The lease is taken before the state file is read AND before the state
        // key is minted, so two coordinators pointed at one output root cannot
        // both decide they are the resumer, and cannot race to create the key.
        using var lease = RunLease.Acquire(request);

        var key = CoordinatorState.LoadOrMintKey(request, out var keyPreexisted);
        var state = CoordinatorState.LoadOrFresh(request, key, keyPreexisted);
        var index = StageArtifactIndex.FromSchema(request.ToolkitRoot);
        // One ledger for every launch this run makes, short or supervised, so that
        // the two things that start processes cannot disagree about what a launch
        // that was never accounted for means.
        var ledger = new LaunchLedger(request, key, keyPreexisted);
        var invoker = new ChildToolInvoker(request, ledger);
        var supervisor = new SlotSupervisor(request, ledger);

        var log = Console.Out;
        log.WriteLine($"shadow-run-coordinator correlationId={request.CorrelationId} state={PreparationStateNames.ToName(state.State)} target={PreparationStateNames.ToName(target)}");

        var machine = new PreparationMachine(request, state, key, index, invoker, supervisor, ledger, log);
        try
        {
            machine.Run(target, haltAfter);
        }
        catch (DeliberateHaltException halt)
        {
            log.WriteLine($"halted at {PreparationStateNames.ToName(halt.State)}");
            return ExitHalted;
        }

        log.WriteLine($"reached {PreparationStateNames.ToName(state.State)} sequence={state.Sequence.ToString(CultureInfo.InvariantCulture)}");
        log.WriteLine($"state file: {request.StatePath}");
        log.WriteLine($"audit file: {request.AuditPath}");
        // A supervised run that ended other than complete is reported with its own
        // exit code, and that is a PASSTHROUGH of the terminal artifact's status
        // rather than a judgement formed here. The coordinator did its job in all
        // three cases: the run it supervised did not. It reads the same for either
        // slot, because a set that stops at slot1 and one that stops at slot2 have
        // stopped for exactly the same reason.
        if (PreparationStateNames.IsUnsuccessfulTerminal(state.State))
        {
            return ExitSlotNotComplete;
        }
        return ExitOk;
    }

    private static string Next(string[] args, ref int index, string name)
    {
        index++;
        if (index >= args.Length)
        {
            throw new ContractException($"'{name}' needs a value.");
        }
        return args[index];
    }

    private const string Usage = """
        ShadowRunCoordinator --request <path> [--target <state>] [--halt-after <state>]
        ShadowRunCoordinator --cohort <path> --authorized-by <alias> [--rebuild-index]
        ShadowRunCoordinator --rebuild-registry --registry <path> --from-cohort <manifest> [...]
                             --authorized-by <alias> [--retract-cleared-holds]
        ShadowRunCoordinator --select-subjects --registry <path> --candidates <path>
                             --out <path> [--select-count <n>]
                             [--accept-unresolved-defects] [--accept-unstarted-registry]
        ShadowRunCoordinator --selftest-atomic-publish <scratch directory>

          --request       Path to a devpilot.shadow-run-coordinator.request.v2 JSON file.
          --target        Stop once this state is reached. Defaults to runSetReady.
          --halt-after    Exit 9 immediately after committing this state. For fault tests.
                          A cohort declared 'shadow-cohort-run' may not forward it.
          --cohort        Path to a devpilot.shadow-cohort.manifest.v3 JSON file. Runs the
                          declared entries one at a time, each as its own preparation
                          against its own immutable output root.
          --authorized-by The operator alias this cohort is started under. Required for
                          --cohort, recorded in the journal and the index, and never
                          defaulted: a cohort is an operator action, not a timer's.
          --rebuild-index Rebuild the cohort index from the journal and the published
                          per-entry audits, and start nothing.
          --selftest-atomic-publish
                          Run the atomic state publish checks under a scratch
                          directory and start nothing. Proves a concurrent reader
                          cannot wedge a publish, that a transient sharing
                          violation is survived, and that an exhausted budget
                          leaves whole old content behind a typed recoverable
                          error rather than a half-published state.
          --rebuild-registry
                          Rebuild the durable subject account from finished cohort roots
                          and start nothing. Every root is read through its own signed
                          journal and per-entry audits; nothing is taken from a summary.
          --registry      Where the account lives. Kept OUTSIDE the repository, because
                          it records what has been spent across branches and heads.
          --from-cohort   A finished cohort's manifest. Repeatable. Roots that cannot be
                          read are reported as defects in the rebuilt account rather
                          than dropped from it.
          --retract-cleared-holds
                          Let go of a subject held ONLY by rows about entries the
                          journals in this rebuild say were never launched. Off by
                          default: a journal minted after the original was lost also
                          reads as never launched, so this is the operator vouching
                          that the journal being read is the original.
          --select-subjects
                          Choose the next subjects from a candidate list, with every
                          subject the account already holds removed. Writes a selection
                          file and starts nothing.
          --candidates    Path to a devpilot.shadow-cohort.candidates.v1 JSON file.
          --select-count  How many unspent subjects to choose. Defaults to 1.
          --out           Where the selection is written.
          --accept-unresolved-defects
                          Choose even though the account records roots it could not
                          read. The exclusion may be incomplete; the acknowledgement
                          is written into the selection file.
          --accept-unstarted-registry
                          Choose against an account file that does not exist yet.
                          Nothing is excluded; the acknowledgement is written into
                          the selection file.

        States: requestValidated corpusStaging corpusPublished corpusValidated
                recipePlanned snapshotValidateOnly snapshotSealed snapshotVerified
                runSetDeclared runSetVerified runSetReady
                slot1Authorized slot1Launching slot1Running slot1TerminalObserved
                slot1TerminalVerified slot1TerminalFailed slot1TerminalTimedOut
                slot2Authorized slot2Launching slot2Running slot2TerminalObserved
                slot2TerminalVerified slot2TerminalFailed slot2TerminalTimedOut
                reconciliationAuthorized reconciliationLaunching
                reconciliationTerminalObserved reconciliationVerified

        The corpus states build the corpus from declared immutable sources and
        require an explicit 'corpusStage' section in the request. Without one they
        commit that nothing was built and the corpus named by 'corpus.root' is
        expected to exist already, which is how every earlier request reads.

        The slot and reconciliation states require an explicit 'slots'
        authorization in the request, which declares BOTH slots from the moment
        the request is written; there is no way to add one later. Without that
        section the coordinator prepares a run set and launches nothing, which
        leaves the PowerShell qualification path the way slots are run.

        slot2 is refused until slot1 has ended verified-complete, and the
        reconciliation is refused until both have. There is no delivery state,
        and no transition under which this program writes to a provider.

        Exit codes: 0 reached, 1 usage, 2 contract refusal, 3 lease conflict,
                    4 child failure, 5 supervised slot ended not-complete,
                    6 a previous run's launch is unaccounted for, 9 deliberate halt.

        A cohort adds two codes and reuses the rest unchanged: 5 also means the
        cohort walked to its stop point with at least one entry other than
        complete, 10 means the cohort stopped on one of its own global budgets
        with its remaining entries left pending, and 11 means something was
        observed that stops the whole set whatever its stop policy says.

        A cohort never retries an entry, never replaces one, and never substitutes
        another subject for one that failed. Its stop policy chooses only between
        ending at the first unsuccessful entry and walking the rest of the set.
        """;
}
