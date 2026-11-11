// Node tests for the Copilot app canvas: the canvas-started Golden watch launcher and the
// instance server's Start/Stop gating. Run: node --test ./tests/CopilotCanvas.Tests.mjs
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { CanvasInstanceServer } from "../src/DevPilot.CopilotCanvas/canvas-server.mjs";
import * as launcher from "../src/DevPilot.CopilotCanvas/watch-launcher.mjs";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

function temp(prefix) {
  return mkdtempSync(join(tmpdir(), prefix));
}

test("the canvas prefers the repository's own Start-DevPilot.ps1 when it supports the canvas, else the recorded toolkit", async () => {
  const extensionDir = temp("canvas-ext-");
  const repo = temp("canvas-repo-");
  try {
    assert.equal(launcher.readToolkit(extensionDir).available, false);
    writeFileSync(join(extensionDir, "toolkit.json"), JSON.stringify({ schemaVersion: 1, toolkitRoot: "relative\\path" }));
    assert.equal(launcher.readToolkit(extensionDir).available, false);
    writeFileSync(join(extensionDir, "toolkit.json"), JSON.stringify({ schemaVersion: 1, toolkitRoot: repositoryRoot, version: "9.9.9" }));
    const toolkit = launcher.readToolkit(extensionDir);
    assert.equal(toolkit.available, true);
    assert.equal(toolkit.watchScript, join(repositoryRoot, "tools", "Watch-DevPilotAgents.ps1"));

    // No repository script: the recorded toolkit's Watch -Golden.
    let entrypoint = await launcher.resolveEntrypoint(repo, { extensionDir });
    assert.equal(entrypoint.kind, "toolkit");
    const toolkitBase = ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", toolkit.watchScript, "-Golden", "-Headless", "-CanvasBridge"];
    assert.deepEqual(launcher.entrypointArguments(entrypoint), toolkitBase);
    assert.deepEqual(launcher.entrypointArguments(entrypoint, { previewOnly: true, whatIf: true }), [...toolkitBase, "-PreviewOnly", "-WhatIf"]);

    // A repository script without both switches is not used (real pwsh parameter probe; never executed).
    const script = join(repo, "Start-DevPilot.ps1");
    writeFileSync(script, "[CmdletBinding()] param([switch]$CanvasBridge) throw 'must not run'\n");
    entrypoint = await launcher.resolveEntrypoint(repo, { extensionDir });
    assert.equal(entrypoint.kind, "toolkit");
    assert.match(entrypoint.repositoryNote, /does not declare -CanvasBridge and -Headless/);

    // A supporting repository script wins, with only the canvas switches added.
    writeFileSync(script, "[CmdletBinding(SupportsShouldProcess)] param([switch]$CanvasBridge, [switch]$Headless, [switch]$PreviewOnly) throw 'must not run'\n");
    entrypoint = await launcher.resolveEntrypoint(repo, { extensionDir });
    assert.equal(entrypoint.kind, "repository");
    assert.equal(entrypoint.script, script);
    assert.deepEqual(launcher.entrypointArguments(entrypoint, { previewOnly: true, whatIf: true }),
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", script, "-CanvasBridge", "-Headless", "-PreviewOnly", "-WhatIf"]);
  } finally {
    rmSync(extensionDir, { recursive: true, force: true });
    rmSync(repo, { recursive: true, force: true });
  }
});
test("Start spawns the watch with output in a launch log and no terminal, and preview uses -WhatIf", async () => {
  const logDirectory = temp("canvas-log-");
  const entrypoint = { kind: "toolkit", script: "C:\\toolkit\\tools\\Watch-DevPilotAgents.ps1" };
  const calls = [];
  const spawnImpl = (file, args, options) => {
    calls.push({ file, args, options });
    const child = new EventEmitter();
    child.pid = 4321;
    child.unref = () => { child.unrefed = true; };
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = () => {};
    calls.at(-1).child = child;
    setImmediate(() => {
      child.stdout.emit("data", "\u001b[36mDevPilot launch plan\u001b[0m\r\n  Mode : PREVIEW ONLY\r\n");
      child.emit("close", 0);
    });
    return child;
  };
  try {
    const launch = launcher.startLaunch({ entrypoint, repositoryRoot: "C:\\repo", previewOnly: false, logDirectory, spawnImpl, now: () => 0 });
    assert.equal(launch.pid, 4321);
    assert.ok(existsSync(launch.logPath));
    assert.equal(calls[0].options.detached, undefined);
    assert.equal(calls[0].options.windowsHide, true);
    assert.equal(calls[0].child.unrefed, true);
    assert.equal(calls[0].options.shell, false);
    assert.equal(calls[0].options.cwd, "C:\\repo");
    assert.equal(calls[0].options.stdio[0], "ignore");
    assert.equal(calls[0].args.includes("-WhatIf"), false);
    assert.equal(calls[0].args.includes("-PreviewOnly"), false);

    const preview = await launcher.previewLaunch({ entrypoint, repositoryRoot: "C:\\repo", previewOnly: true, spawnImpl });
    assert.equal(preview.ok, true);
    assert.equal(preview.output, "DevPilot launch plan\n  Mode : PREVIEW ONLY\n");
    assert.deepEqual(calls[1].args.slice(-2), ["-PreviewOnly", "-WhatIf"]);
    assert.equal(calls[1].options.detached, undefined);

    // A spawn failure is recorded on the launch instead of crashing the extension.
    const failing = launcher.startLaunch({
      entrypoint, repositoryRoot: "C:\\missing", previewOnly: false, logDirectory, now: () => 1,
      spawnImpl: () => {
        const child = new EventEmitter();
        setImmediate(() => child.emit("error", new Error("spawn pwsh ENOENT")));
        return child;
      },
    });
    await new Promise((resolveWait) => setImmediate(resolveWait));
    assert.equal(failing.pid, 0);
    assert.match(failing.error, /ENOENT/);
  } finally {
    rmSync(logDirectory, { recursive: true, force: true });
  }
});

async function startBridgeStub() {
  const shutdowns = [];
  const server = createServer((req, res) => {
    if (req.method === "POST" && req.url === "/v1/shutdown") shutdowns.push(req.headers.authorization);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(req.url === "/v1/shutdown" ? { stopping: true } : {
      schemaVersion: 1, launchMode: "operational", headless: true, consumerRepositoryRoot: repositoryRoot,
      dashboardPid: process.pid, view: "current", automation: { available: false }, instances: [], runs: [], queued: [],
    }));
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  return { server, shutdowns, url: `http://127.0.0.1:${server.address().port}/` };
}

test("the canvas server starts a watch only from a fresh human-previewed plan and stops only a headless watch", async () => {
  const watchRoot = temp("canvas-watch-");
  const previews = [];
  const starts = [];
  const fakeLauncher = {
    ...launcher,
    resolveEntrypoint: async (root) => ({
      available: true, kind: "toolkit", script: "C:\\toolkit\\tools\\Watch-DevPilotAgents.ps1", repositoryRoot: root,
      toolkitRoot: "C:\\toolkit", version: "9.9.9", repositoryNote: "",
    }),
    previewLaunch: async (options) => { previews.push(options); return { ok: true, exitCode: 0, output: "DevPilot launch plan" }; },
    startLaunch: (options) => { starts.push(options); return { pid: process.pid, logPath: join(watchRoot, "launch.log"), startedAt: Date.now(), previewOnly: options.previewOnly }; },
    logTail: () => "",
  };
  const server = new CanvasInstanceServer({ workingDirectory: repositoryRoot, watchRoot, launcher: fakeLauncher });
  const bridge = await startBridgeStub();
  await server.start();
  const nonceHtml = await (await fetch(server.url)).text();
  const nonce = /name="devpilot-nonce" content="([^"]+)"/.exec(nonceHtml)[1];
  const post = async (path, body, headers = {}) => {
    const response = await fetch(new URL(path, server.url), {
      method: "POST", headers: { "content-type": "application/json", "x-canvas-nonce": nonce, ...headers }, body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  };
  try {
    const state = await (await fetch(new URL("/api/state", server.url), { headers: { "x-canvas-nonce": nonce } })).json();
    assert.equal(state.connection.state, "no-bridge");
    assert.equal(state.connection.launcher.available, true);

    assert.equal((await post("/api/watch/start", { launchToken: "guess" })).body.error, "launch-repreview-required");
    assert.equal((await post("/api/watch/preview", { previewOnly: true }, { "x-canvas-nonce": "wrong" })).status, 403);
    const preview = await post("/api/watch/preview", { previewOnly: true });
    assert.equal(preview.status, 200);
    assert.equal(preview.body.ok, true);
    assert.equal(previews[0].previewOnly, true);
    assert.equal(starts.length, 0);

    const started = await post("/api/watch/start", { launchToken: preview.body.launchToken });
    assert.equal(started.status, 200);
    assert.equal(starts.length, 1);
    assert.equal(starts[0].previewOnly, true);
    assert.equal(starts[0].repositoryRoot, preview.body.repositoryRoot);
    assert.equal(starts[0].entrypoint.script, "C:\\toolkit\\tools\\Watch-DevPilotAgents.ps1");
    assert.equal(previews[0].entrypoint.kind, "toolkit");
    assert.equal((await post("/api/watch/start", { launchToken: preview.body.launchToken })).status, 409);

    // A terminal-owned watch cannot be stopped from the canvas; a headless one can.
    const watchDirectory = join(watchRoot, "20261110T000000Z-0123abcd");
    mkdirSync(watchDirectory);
    const discovery = {
      schemaVersion: 1, url: bridge.url, token: "bridge-token", dashboardPid: process.pid,
      consumerRepositoryRoot: preview.body.repositoryRoot, launchMode: "operational", headless: false,
      startedAtUtc: new Date().toISOString(),
    };
    writeFileSync(join(watchDirectory, "canvas-bridge.v1.json"), JSON.stringify(discovery));
    assert.equal((await post("/api/watch/stop", {})).body.error, "terminal-owned");
    writeFileSync(join(watchDirectory, "canvas-bridge.v1.json"), JSON.stringify({ ...discovery, headless: true }));
    assert.equal((await post("/api/watch/preview", { previewOnly: false })).status, 409);
    const stopped = await post("/api/watch/stop", {});
    assert.equal(stopped.status, 200);
    assert.deepEqual(bridge.shutdowns, ["Bearer bridge-token"]);
    assert.equal(JSON.parse(readFileSync(join(watchDirectory, "canvas-bridge.v1.json"), "utf8")).headless, true);
  } finally {
    server.close();
    bridge.server.closeAllConnections();
    bridge.server.close();
    rmSync(watchRoot, { recursive: true, force: true });
  }
});
