using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class StalePrSlowTokenProcess
{
    public static int Main(string[] args)
    {
        string logPath = Environment.GetEnvironmentVariable(
            "DEVPILOT_STALE_PR_TOKEN_PID_LOG");
        if (string.IsNullOrWhiteSpace(logPath))
        {
            return 91;
        }

        bool child = args.Length == 1 && args[0] == "--child";
        if (child)
        {
            File.AppendAllText(logPath, $"child={Environment.ProcessId}\n");
            Thread.Sleep(TimeSpan.FromSeconds(30));
            return 0;
        }

        File.AppendAllText(logPath, $"parent={Environment.ProcessId}\n");
        using Process process = Process.Start(new ProcessStartInfo
        {
            FileName = Environment.ProcessPath,
            Arguments = "--child",
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        Thread.Sleep(TimeSpan.FromSeconds(30));
        return 0;
    }
}
