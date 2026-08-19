using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace DevPilot.ShadowRunCoordinator;

internal sealed class ChildFailureException(string message) : Exception(message);

internal sealed record ChildOutcome(int ExitCode, string ResultPath, JsonElement Result, string ResultSha256);

/// <summary>
/// The only way this coordinator starts a process.
/// </summary>
/// <remarks>
/// Four rules, each of which is a fault this design refuses to leave available.
///
/// One child at a time, synchronously. A control plane that can have two children
/// in flight has to reason about which one wrote a file, and this slice has no
/// need of that.
///
/// The contract is a file, never standard output. The child is told where to read
/// its request and where to write its result. Standard output and standard error
/// are captured to log files for a human and are never parsed: a diagnostic line
/// from a well-meaning helper cannot become part of a decision.
///
/// A bounded wait, and a kill that takes the whole tree. A child that hangs is
/// killed along with anything it started, so a timeout cannot leave an orphan
/// holding a file handle on the output root.
///
/// A result the child did not write is not a result. A missing, empty, truncated,
/// byte-order-marked or wrong-versioned result file fails the step even when the
/// child exited zero, because a zero exit from a partially written step is
/// exactly the fault a file contract exists to catch.
/// </remarks>
internal sealed class ChildToolInvoker(CoordinatorRequest request)
{
    internal const string ResultContractVersion = "devpilot.shadow-run-coordinator.child-result.v1";

    private readonly CoordinatorRequest _request = request;
    private bool _childInFlight;

    internal ChildOutcome Invoke(string step, string scriptPath, MapNode childRequest, params string[] expectedResultFields)
    {
        if (_childInFlight)
        {
            throw new ContractException("A second child was requested while one was still in flight; this coordinator runs one child at a time.");
        }

        Directory.CreateDirectory(_request.ExchangeRoot);
        Directory.CreateDirectory(_request.LogRoot);

        var stem = _request.CorrelationId + "-" + step;
        var requestPath = Path.Combine(_request.ExchangeRoot, stem + ".request.json");
        var resultPath = Path.Combine(_request.ExchangeRoot, stem + ".result.json");
        var outLog = Path.Combine(_request.LogRoot, stem + ".out.log");
        var errorLog = Path.Combine(_request.LogRoot, stem + ".err.log");

        childRequest.Set("correlationId", _request.CorrelationId);
        childRequest.Set("step", step);
        childRequest.Set("resultPath", resultPath);
        CanonicalJson.WriteFileAtomic(requestPath, CanonicalJson.Readable(childRequest));

        // A result left over from a previous attempt would let a child that never
        // ran look like one that succeeded.
        if (File.Exists(resultPath))
        {
            File.Delete(resultPath);
        }

        var start = new ProcessStartInfo
        {
            FileName = _request.PowerShellPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = StrictJson.StrictUtf8,
            StandardErrorEncoding = StrictJson.StrictUtf8,
            WorkingDirectory = _request.ToolkitRoot,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-File");
        start.ArgumentList.Add(scriptPath);
        start.ArgumentList.Add("-RequestPath");
        start.ArgumentList.Add(requestPath);

        _childInFlight = true;
        var standardOut = new StringBuilder();
        var standardError = new StringBuilder();
        Process? process = null;
        try
        {
            process = Process.Start(start) ?? throw new ChildFailureException($"The '{step}' child did not start.");
            process.OutputDataReceived += (_, args) => { if (args.Data is not null) { standardOut.AppendLine(args.Data); } };
            process.ErrorDataReceived += (_, args) => { if (args.Data is not null) { standardError.AppendLine(args.Data); } };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.StandardInput.Close();

            var budget = TimeSpan.FromSeconds(_request.ChildTimeoutSeconds);
            if (!process.WaitForExit((int)budget.TotalMilliseconds))
            {
                KillTree(process);
                WriteLogs(outLog, errorLog, standardOut, standardError);
                throw new ChildFailureException(
                    $"The '{step}' child exceeded its {_request.ChildTimeoutSeconds.ToString(CultureInfo.InvariantCulture)} second budget and was killed with its process tree.");
            }
            // Lets the asynchronous readers drain; without it the logs can lose
            // the last lines the child wrote before exiting.
            process.WaitForExit();
            WriteLogs(outLog, errorLog, standardOut, standardError);

            if (process.ExitCode != 0)
            {
                throw new ChildFailureException(
                    $"The '{step}' child exited {process.ExitCode.ToString(CultureInfo.InvariantCulture)}; see '{errorLog}'.");
            }
        }
        finally
        {
            _childInFlight = false;
            if (process is not null)
            {
                // Belt and braces against an orphan: if anything above threw
                // between start and exit, the tree goes with it.
                if (!process.HasExited)
                {
                    KillTree(process);
                }
                process.Dispose();
            }
        }

        var label = $"'{step}' child result";
        // A malformed result is the CHILD's failure, not the caller's. Letting a
        // strict-reader refusal surface as a request-contract failure would tell
        // an operator to go and fix a request that is perfectly well formed.
        JsonElement result;
        try
        {
            result = StrictJson.ReadObjectFile(resultPath, label);
            StrictJson.RequireLiteral(result, "contractVersion", ResultContractVersion, label);
            StrictJson.RequireLiteral(result, "step", step, label);
            StrictJson.RequireLiteral(result, "correlationId", _request.CorrelationId, label);
        }
        catch (ContractException error)
        {
            throw new ChildFailureException(error.Message);
        }
        if (!StrictJson.RequireBool(result, "ok", label))
        {
            throw new ChildFailureException($"The '{step}' child reported failure in its result file.");
        }
        foreach (var field in expectedResultFields)
        {
            if (!result.TryGetProperty(field, out _))
            {
                throw new ChildFailureException($"The '{step}' child result is missing required field '{field}'.");
            }
        }
        return new ChildOutcome(0, resultPath, result, CanonicalJson.Sha256HexOfFile(resultPath));
    }

    private static void KillTree(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit(30_000);
        }
        catch (InvalidOperationException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
        catch (NotSupportedException)
        {
        }
    }

    private static void WriteLogs(string outLog, string errorLog, StringBuilder standardOut, StringBuilder standardError)
    {
        File.WriteAllText(outLog, standardOut.ToString(), StrictJson.StrictUtf8);
        File.WriteAllText(errorLog, standardError.ToString(), StrictJson.StrictUtf8);
    }
}
