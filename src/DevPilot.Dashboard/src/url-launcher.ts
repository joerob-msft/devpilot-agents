import { spawn, type SpawnOptions } from "node:child_process";

export const WINDOWS_URL_ENVIRONMENT_NAME = "DEVPILOT_DASHBOARD_OPEN_URL";
export const WINDOWS_ASSOCIATION_LAUNCHER_ENVIRONMENT_NAME =
  "DEVPILOT_DASHBOARD_URL_ASSOCIATION_LAUNCHER";
export const WINDOWS_ASSOCIATION_ARGUMENTS_ENVIRONMENT_NAME =
  "DEVPILOT_DASHBOARD_URL_ASSOCIATION_ARGUMENTS";

const WINDOWS_OPEN_SCRIPT = [
  "$ErrorActionPreference='Stop'",
  `$url=$env:${WINDOWS_URL_ENVIRONMENT_NAME}`,
  "if([string]::IsNullOrWhiteSpace($url)){throw 'Validated URL was not provided.'}",
  "Start-Process -FilePath $url -ErrorAction Stop | Out-Null",
].join(";");

const WINDOWS_TEST_ASSOCIATION_SCRIPT = [
  "$ErrorActionPreference='Stop'",
  `$url=$env:${WINDOWS_URL_ENVIRONMENT_NAME}`,
  `$launcher=$env:${WINDOWS_ASSOCIATION_LAUNCHER_ENVIRONMENT_NAME}`,
  "if([string]::IsNullOrWhiteSpace($url)-or[string]::IsNullOrWhiteSpace($launcher)){throw 'URL association test inputs were not provided.'}",
  `$launcherArguments=@($env:${WINDOWS_ASSOCIATION_ARGUMENTS_ENVIRONMENT_NAME}|ConvertFrom-Json)`,
  "$process=Start-Process -FilePath $launcher -ArgumentList $launcherArguments -PassThru -Wait -NoNewWindow -ErrorAction Stop",
  "if($process.ExitCode -ne 0){exit $process.ExitCode}",
].join(";");

export interface WindowsAssociationLauncher {
  command: string;
  args: string[];
  environment?: NodeJS.ProcessEnv;
}

export interface UrlLaunchPlan {
  command: string;
  args: string[];
  options: SpawnOptions;
  completion: "spawn" | "exit";
  timeoutMilliseconds: number;
}

export interface UrlLaunchPlanOptions {
  platform?: NodeJS.Platform;
  environment?: NodeJS.ProcessEnv;
  windowsPowerShellExecutable?: string;
  windowsAssociationLauncher?: WindowsAssociationLauncher;
}

export function safeHttpUrl(value: string): string | null {
  if (!value || value.length > 2_048) return null;
  try {
    const parsed = new URL(value);
    if (
      (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
      !parsed.hostname ||
      parsed.username ||
      parsed.password
    ) {
      return null;
    }
    return parsed.href;
  } catch {
    return null;
  }
}

export function createUrlLaunchPlan(
  value: string,
  options: UrlLaunchPlanOptions = {},
): UrlLaunchPlan {
  const url = safeHttpUrl(value);
  if (!url) throw new Error("PR URL is missing or unsupported");
  const platform = options.platform ?? process.platform;
  const environment = options.environment ?? process.env;
  if (platform === "win32") {
    const association = options.windowsAssociationLauncher;
    return {
      command: options.windowsPowerShellExecutable ?? "pwsh.exe",
      args: [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        association ? WINDOWS_TEST_ASSOCIATION_SCRIPT : WINDOWS_OPEN_SCRIPT,
      ],
      options: {
        detached: false,
        stdio: "ignore",
        windowsHide: true,
        shell: false,
        env: {
          ...environment,
          ...association?.environment,
          [WINDOWS_URL_ENVIRONMENT_NAME]: url,
          ...(association ? {
            [WINDOWS_ASSOCIATION_LAUNCHER_ENVIRONMENT_NAME]: association.command,
            [WINDOWS_ASSOCIATION_ARGUMENTS_ENVIRONMENT_NAME]: JSON.stringify(association.args),
          } : {}),
        },
      },
      completion: "exit",
      timeoutMilliseconds: 15_000,
    };
  }
  const command = platform === "darwin" ? "open" : platform === "linux" ? "xdg-open" : "";
  if (!command) throw new Error(`URL opening is unavailable on ${platform}`);
  return {
    command,
    args: [url],
    options: {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
      shell: false,
    },
    completion: "spawn",
    timeoutMilliseconds: 0,
  };
}

export function executeUrlLaunchPlan(
  plan: UrlLaunchPlan,
  spawnProcess: typeof spawn = spawn,
): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (error?: Error): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (error) reject(error);
      else resolve();
    };
    const child = spawnProcess(plan.command, plan.args, plan.options);
    child.once("error", (error) => finish(error));
    if (plan.completion === "spawn") {
      child.once("spawn", () => {
        child.unref();
        finish();
      });
      return;
    }
    if (plan.timeoutMilliseconds > 0) {
      timer = setTimeout(() => {
        child.kill();
        finish(new Error(`URL launcher timed out after ${plan.timeoutMilliseconds} ms`));
      }, plan.timeoutMilliseconds);
    }
    child.once("close", (code, signal) => {
      if (code === 0) finish();
      else finish(new Error(
        signal
          ? `URL launcher terminated by signal ${signal}`
          : `URL launcher exited with code ${code ?? "unknown"}`,
      ));
    });
  });
}

export function defaultOpenUrl(value: string): Promise<void> {
  try {
    return executeUrlLaunchPlan(createUrlLaunchPlan(value));
  } catch (error) {
    return Promise.reject(error);
  }
}
