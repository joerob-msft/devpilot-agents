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

        string mode = Environment.GetEnvironmentVariable(
            "DEVPILOT_STALE_PR_TOKEN_MODE") ?? "sleep-tree";
        bool child = args.Length == 1 && args[0] == "--child";
        if (child)
        {
            File.AppendAllText(logPath, $"child={Environment.ProcessId}\n");
            Thread.Sleep(TimeSpan.FromSeconds(30));
            return 0;
        }

        File.AppendAllText(logPath, $"parent={Environment.ProcessId}\n");
        if (mode == "stdout-overrun")
        {
            Console.Out.Write(new string('O', 2 * 1024 * 1024));
            Thread.Sleep(TimeSpan.FromSeconds(30));
            return 0;
        }
        if (mode == "stderr-overrun")
        {
            Console.Error.Write(new string('E', 128 * 1024));
            Thread.Sleep(TimeSpan.FromSeconds(30));
            return 0;
        }
        using Process process = Process.Start(new ProcessStartInfo
        {
            FileName = Environment.ProcessPath,
            Arguments = "--child",
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        if (mode == "descendant-holds-pipes")
        {
            return 0;
        }
        Thread.Sleep(TimeSpan.FromSeconds(30));
        return 0;
    }
}
