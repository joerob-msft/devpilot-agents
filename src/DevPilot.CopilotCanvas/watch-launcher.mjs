// Starts a canvas-owned (headless) Golden watch. Pure Node so it can be tested without the SDK.
// The canvas never chooses capabilities: it runs the recorded toolkit's own
// Watch-DevPilotAgents.ps1 -Golden -Headless -CanvasBridge from the repository root, with the
// optional -PreviewOnly ceiling, after the user has seen that script's -WhatIf launch plan.
import { spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const EXTENSION_DIR = dirname(fileURLToPath(import.meta.url));
const PREVIEW_TIMEOUT_MS = 120_000;
const MAX_OUTPUT_CHARS = 20_000;
const ANSI = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;

export function watchScriptPath(toolkitRoot) {
  return join(toolkitRoot, "tools", "Watch-DevPilotAgents.ps1");
}

// toolkit.json is written by tools/Install-DevPilotCanvas.ps1 and names the toolkit to launch.
export function readToolkit(extensionDir = EXTENSION_DIR) {
  const file = join(extensionDir, "toolkit.json");
  if (!existsSync(file)) {
    return { available: false, reason: "No toolkit is recorded. Re-run tools\\Install-DevPilotCanvas.ps1 from the DevPilot toolkit to enable Start." };
  }
  try {
    const value = JSON.parse(readFileSync(file, "utf8"));
    const toolkitRoot = typeof value?.toolkitRoot === "string" ? value.toolkitRoot : "";
    if (value?.schemaVersion !== 1 || !toolkitRoot || !isAbsolute(toolkitRoot)) throw new Error("invalid toolkit.json");
    const watchScript = watchScriptPath(toolkitRoot);
    if (!existsSync(watchScript)) {
      return { available: false, toolkitRoot, reason: `The recorded toolkit has no ${watchScript}. Re-run Install-DevPilotCanvas.ps1.` };
    }
    return { available: true, toolkitRoot, version: typeof value.version === "string" ? value.version : "", watchScript };
  } catch {
    return { available: false, reason: "toolkit.json is unreadable. Re-run tools\\Install-DevPilotCanvas.ps1." };
  }
}

export function watchArguments(watchScript, { previewOnly = false, whatIf = false } = {}) {
  return [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-File", watchScript,
    "-Golden", "-Headless", "-CanvasBridge",
    ...(previewOnly ? ["-PreviewOnly"] : []),
    ...(whatIf ? ["-WhatIf"] : []),
  ];
}

export function displayCommand(watchScript, options) {
  return ["pwsh", ...watchArguments(watchScript, options).slice(3)]
    .map((part) => (/\s/.test(part) ? `"${part}"` : part)).join(" ");
}

export function defaultLaunchLogDirectory(env = process.env) {
  if (process.platform === "win32") {
    return join(env.LOCALAPPDATA || join(homedir(), "AppData", "Local"), "DevPilot", "canvas");
  }
  return join(env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "devpilot", "canvas");
}

function cleanOutput(text) {
  const clean = text.replace(ANSI, "").replace(/\r\n/g, "\n");
  return clean.length > MAX_OUTPUT_CHARS ? `…${clean.slice(-MAX_OUTPUT_CHARS)}` : clean;
}

// Runs the same command with -WhatIf: Watch prints its launch plan (or its aggregated preflight
// failures) and stops before creating any state, descriptor or process.
export function previewLaunch({ toolkit, repositoryRoot, previewOnly, pwsh = "pwsh", spawnImpl = spawn }) {
  return new Promise((resolvePreview) => {
    let output = "";
    let settled = false;
    const finish = (exitCode, extra = "") => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolvePreview({ ok: exitCode === 0, exitCode, output: cleanOutput(output + extra) });
    };
    const child = spawnImpl(pwsh, watchArguments(toolkit.watchScript, { previewOnly, whatIf: true }), {
      cwd: repositoryRoot, shell: false, windowsHide: true, stdio: ["ignore", "pipe", "pipe"],
    });
    const timer = setTimeout(() => {
      child.kill();
      finish(-1, "\nThe launch plan preview timed out.");
    }, PREVIEW_TIMEOUT_MS);
    child.stdout?.on("data", (chunk) => { output += chunk; });
    child.stderr?.on("data", (chunk) => { output += chunk; });
    child.once("error", (error) => finish(-1, `\nCould not run pwsh: ${error.message}`));
    child.once("close", (code) => finish(code ?? -1));
  });
}

// Outlives extension reloads, /clear and closing the canvas (Node never kills its children on exit);
// the canvas re-attaches through canvas-bridge.v1.json and stops it only through the bridge's
// headless shutdown route. The Copilot app runs extensions inside a kill-on-close job object without
// breakaway, so quitting the app ends the watch too; that host containment is respected, not evaded.
// Deliberately NOT `detached`: on Windows that is DETACHED_PROCESS, and pwsh without any console
// silently drops all output and the Watch cannot run its dashboard and broker.
export function startLaunch({
  toolkit, repositoryRoot, previewOnly, pwsh = "pwsh", logDirectory = defaultLaunchLogDirectory(),
  spawnImpl = spawn, now = Date.now,
}) {
  mkdirSync(logDirectory, { recursive: true });
  const stamp = new Date(now()).toISOString().replace(/[:.]/g, "-");
  const logPath = join(logDirectory, `watch-launch-${stamp}.log`);
  const fd = openSync(logPath, "a");
  try {
    const child = spawnImpl(pwsh, watchArguments(toolkit.watchScript, { previewOnly }), {
      cwd: repositoryRoot, shell: false, windowsHide: true, stdio: ["ignore", fd, fd],
    });
    const launch = { pid: child.pid ?? 0, logPath, startedAt: now(), previewOnly, error: "" };
    // An unhandled spawn 'error' would crash the whole extension; record it on the launch instead.
    child.once?.("error", (error) => { launch.error = `Could not start pwsh: ${error.message}`; });
    child.unref?.();
    return launch;
  } finally {
    closeSync(fd);
  }
}

export function logTail(logPath, maxBytes = 6_000) {
  try {
    const size = statSync(logPath).size;
    const length = Math.min(size, maxBytes);
    const buffer = Buffer.alloc(length);
    const fd = openSync(logPath, "r");
    try {
      readSync(fd, buffer, 0, length, size - length);
    } finally {
      closeSync(fd);
    }
    return cleanOutput(buffer.toString("utf8"));
  } catch {
    return "";
  }
}
