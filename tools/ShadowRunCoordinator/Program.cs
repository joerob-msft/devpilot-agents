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
    private const int ExitOk = 0;
    private const int ExitUsage = 1;
    private const int ExitContract = 2;
    private const int ExitLeaseConflict = 3;
    private const int ExitChildFailure = 4;
    private const int ExitHalted = 9;

    internal static int Main(string[] args)
    {
        string? requestPath = null;
        string? targetName = null;
        string? haltAfterName = null;

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
                case "--help":
                    Console.Out.WriteLine(Usage);
                    return ExitOk;
                default:
                    Console.Error.WriteLine($"Unrecognised argument '{args[index]}'.");
                    Console.Error.WriteLine(Usage);
                    return ExitUsage;
            }
        }

        if (requestPath is null)
        {
            Console.Error.WriteLine("A --request path is required.");
            Console.Error.WriteLine(Usage);
            return ExitUsage;
        }

        try
        {
            var request = CoordinatorRequest.Load(requestPath);
            var target = targetName is null ? PreparationState.RunSetReady : PreparationStateNames.Parse(targetName);
            var haltAfter = haltAfterName is null ? (PreparationState?)null : PreparationStateNames.Parse(haltAfterName);
            if (haltAfter is not null && haltAfter > target)
            {
                throw new ContractException($"--halt-after '{PreparationStateNames.ToName(haltAfter.Value)}' is beyond --target '{PreparationStateNames.ToName(target)}'.");
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
        catch (ChildFailureException error)
        {
            Console.Error.WriteLine(error.Message);
            return ExitChildFailure;
        }
    }

    private static int Run(CoordinatorRequest request, PreparationState target, PreparationState? haltAfter)
    {
        Directory.CreateDirectory(request.OutputRoot);
        Directory.CreateDirectory(request.CoordinatorRoot);

        var key = CoordinatorState.LoadOrMintKey(request);

        // The lease is taken before the state file is read, so two coordinators
        // pointed at one output root cannot both decide they are the resumer.
        using var lease = RunLease.Acquire(request);

        var state = CoordinatorState.LoadOrFresh(request, key);
        var index = StageArtifactIndex.FromSchema(request.ToolkitRoot);
        var invoker = new ChildToolInvoker(request);

        var log = Console.Out;
        log.WriteLine($"shadow-run-coordinator correlationId={request.CorrelationId} state={PreparationStateNames.ToName(state.State)} target={PreparationStateNames.ToName(target)}");

        var machine = new PreparationMachine(request, state, key, index, invoker, log);
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

          --request     Path to a devpilot.shadow-run-coordinator.request.v1 JSON file.
          --target      Stop once this state is reached. Defaults to runSetReady.
          --halt-after  Exit 9 immediately after committing this state. For fault tests.

        States: requestValidated corpusValidated recipePlanned snapshotValidateOnly
                snapshotSealed snapshotVerified runSetDeclared runSetVerified runSetReady

        Exit codes: 0 reached, 1 usage, 2 contract refusal, 3 lease conflict,
                    4 child failure, 9 deliberate halt.
        """;
}
