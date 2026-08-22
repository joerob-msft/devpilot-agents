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
        var rebuildIndex = false;

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
                    case "--help":
                        Console.Out.WriteLine(Usage);
                        return ExitOk;
                    default:
                        Console.Error.WriteLine($"Unrecognised argument '{args[index]}'.");
                        Console.Error.WriteLine(Usage);
                        return ExitUsage;
                }
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

          --request       Path to a devpilot.shadow-run-coordinator.request.v2 JSON file.
          --target        Stop once this state is reached. Defaults to runSetReady.
          --halt-after    Exit 9 immediately after committing this state. For fault tests.
                          A cohort declared 'shadow-cohort-run' may not forward it.
          --cohort        Path to a devpilot.shadow-cohort.manifest.v2 JSON file. Runs the
                          declared entries one at a time, each as its own preparation
                          against its own immutable output root.
          --authorized-by The operator alias this cohort is started under. Required for
                          --cohort, recorded in the journal and the index, and never
                          defaulted: a cohort is an operator action, not a timer's.
          --rebuild-index Rebuild the cohort index from the journal and the published
                          per-entry audits, and start nothing.

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
