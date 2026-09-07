import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { access, appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import test from "node:test";
import { stripVTControlCharacters } from "node:util";
import { execFileSync } from "node:child_process";
import { spawn, type IDisposable, type IPty } from "node-pty";
import { TerminalScreen } from "./terminal-screen.js";

const WAIT_TIMEOUT_MS = 8_000;
const EXIT_TIMEOUT_MS = 5_000;
const MAX_CAPTURE_CHARS = 1_000_000;
const SIMPLE_MAIN_HINT = "m Start agent | h History | a Advanced | q Quit";

test("real Delete dismisses stale instances across dashboard restarts and Live only stays the default", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 60_000,
}, async () => {
  const root = await mkdtemp(resolve(".devpilot-dismissal-pty-"));
  const log = join(root, "events.jsonl");
  const contents = event("reviewer", "dismissal-pty", 1, "agent.started", { repository: "old-watch" }) + "\n";
  let expectedContents = contents;
  const dashboardRoot = resolve(".");
  const bun = resolve("node_modules", "bun", "bin", "bun.exe");
  try {
    await writeFile(log, contents);
    for (let launch = 0; launch < 2; launch++) {
      const terminal = spawn(bun, ["--conditions=browser", resolve("dist", "src", "index.js"),
        "--event-log", log, "--view-state-dir", join(root, "display")], {
        name: "xterm-256color", cols: 130, rows: 36, cwd: dashboardRoot, env: environment(),
      });
      let revision = 0;
      let raw = "";
      let exited = false;
      const screen = new TerminalScreen();
      const output = terminal.onData((data) => {
        raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
        screen.write(data);
        revision++;
      });
      let resolveExit!: (event: PtyExit) => void;
      const exit = new Promise<PtyExit>((resolve) => { resolveExit = resolve; });
      const subscription = terminal.onExit((result) => { exited = true; resolveExit(result); });
      const visible = () => screen.text();
      async function wait(expected: string, start = 0): Promise<void> {
        const deadline = Date.now() + WAIT_TIMEOUT_MS;
        while (Date.now() < deadline && !exited) {
          if (revision >= start && visible().includes(expected)) return;
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        assert.fail(`Missing ${expected}\n${visible()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`);
      }
      async function send(bytes: string, expected: string): Promise<void> {
        const start = revision + 1;
        terminal.write(bytes);
        await wait(expected, start);
      }
      async function finish(): Promise<PtyExit> {
        let timeout: NodeJS.Timeout | undefined;
        try {
          return await Promise.race([exit, new Promise<never>((_, reject) => {
            timeout = setTimeout(() => reject(new Error("Dashboard did not exit")), EXIT_TIMEOUT_MS);
          })]);
        } finally { if (timeout) clearTimeout(timeout); }
      }
      try {
        await wait(SIMPLE_MAIN_HINT);
        await send("a", "FOCUS RAIL");
        await wait("LIVE ONLY");
        await wait("INSTANCES 0");
        await send("F", "operations-dashboard PR #104"); // Wait for replay, not just the initially empty frame.
        await wait("PR HISTORY 1");
        await send("l", "Live only 0");
        await send("l", "CURRENT SESSION");
        await wait(`INSTANCES ${launch === 0 ? 1 : 0}`);
        if (launch === 0) {
          await send("\x1b[3~", "Instance dismissed across Watch restarts");
          await wait("INSTANCES 0");
          await send("f", "operations-dashboard PR #104");
          await wait("PR HISTORY 1");
        } else {
          await send("\x1b[3;2~", "1 dismissed instance(s) restored");
          await wait("INSTANCES 1");
          assert.equal(await readFile(log, "utf8"), contents);
          await send("\x1b[3~", "Instance dismissed across Watch restarts");
          await wait("INSTANCES 0");
          const heartbeat = JSON.parse(contents);
          heartbeat.sequence = 2;
          heartbeat.eventType = "agent.heartbeat";
          heartbeat.timestamp = new Date().toISOString();
          const heartbeatLine = JSON.stringify(heartbeat) + "\n";
          await appendFile(log, heartbeatLine);
          expectedContents += heartbeatLine;
          await send("l", "Live only 1");
          await send("\x1b[3~", "Live agents cannot be dismissed");
          await wait("INSTANCES 1");
        }
        assert.equal(await readFile(log, "utf8"), expectedContents);
        terminal.write("q");
        const result = await finish();
        assert.equal(result.exitCode, 0);
        assert.equal(result.signal ?? 0, 0);
        assert.equal(await readFile(log, "utf8"), expectedContents);
      } finally {
        if (!exited) { terminal.kill(); await finish(); }
        disposeConptyOutputWorker(terminal);
        output.dispose();
        subscription.dispose();
      }
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

interface PtyExit {
  exitCode: number;
  signal?: number;
}

interface WindowsPtyLifecycle extends IPty {
  _agent?: {
    _conoutSocketWorker?: IDisposable;
  };
}

function disposeConptyOutputWorker(terminal: IPty): void {
  // node-pty 1.1.0 leaves this worker referenced after natural exit and exposes no public non-killing close.
  (terminal as WindowsPtyLifecycle)._agent?._conoutSocketWorker?.dispose();
}

function event(
  role: "reviewer" | "review-handler",
  instanceId: string,
  sequence: number,
  eventType: string,
  data: Record<string, unknown>,
): string {
  return JSON.stringify({
    schemaVersion: 3,
    agent: role,
    instanceId,
    processId: role === "reviewer" ? 4104 : 4105,
    timestamp: new Date(Date.parse("2026-09-03T15:00:00Z") + sequence * 1_000).toISOString(),
    sequence,
    eventType,
    level: eventType === "delivery.blocked" ? "warning" : "info",
    cycleNumber: 1,
    pullRequestId: 104,
    sourceCommit: "a8075dc0a8075dc0a8075dc0a8075dc0a8075dc0",
    repositoryIdentity: {
      schemaVersion: 1,
      provider: "GitHub",
      repositoryId: "10400000000000001",
      organization: "devpilot",
      project: "",
      repositoryName: "operations-dashboard",
      slug: "devpilot/operations-dashboard",
      key: "v1:github:10400000000000001",
      verifiedAtUtc: "2026-09-03T15:00:00Z",
      verified: true,
      dispatchEligible: true,
    },
    dispatch: null,
    data,
    message: "",
  });
}

function fixtureLines(): string {
  const scrollEvents = Array.from({ length: 32 }, (_, index) =>
    event("reviewer", "pty-reviewer", index + 4, "phase.changed", {
      phase: `scroll marker ${String(index + 1).padStart(2, "0")}`,
    }));
  return [
    event("reviewer", "pty-reviewer", 1, "agent.started", { repository: "operations-dashboard" }),
    event("reviewer", "pty-reviewer", 2, "candidate.selected", {
      title: "ConPTY live flow",
      author: "Ada",
      url: "https://github.com/devpilot/operations-dashboard/pull/104",
      sourceBranch: "joerob/issue-104",
      targetBranch: "main",
    }),
    event("reviewer", "pty-reviewer", 3, "delivery.blocked", {
      reason: "Deterministic fixture warning",
      outstanding: ["summary"],
    }),
    ...scrollEvents,
    event("reviewer", "pty-reviewer", 36, "work.completed", {
      result: "reviewed",
      summary: "Renderer and protocol verification complete",
    }),
    event("reviewer", "pty-reviewer", 37, "agent.stopped", {}),
    event("review-handler", "pty-handler", 1, "agent.started", { repository: "operations-dashboard" }),
    event("review-handler", "pty-handler", 2, "candidate.selected", {
      title: "ConPTY live flow",
      author: "Ada",
      url: "https://github.com/devpilot/operations-dashboard/pull/104",
      sourceBranch: "joerob/issue-104",
      targetBranch: "main",
    }),
    event("review-handler", "pty-handler", 3, "work.completed", {
      result: "handled",
      summary: "No remaining comments",
    }),
    event("review-handler", "pty-handler", 4, "agent.stopped", {}),
  ].join("\n") + "\n";
}

test("real ConPTY defaults to Simple across widths, retains History and starts agents with two Enters", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 120_000,
}, async () => {
  for (const width of [70, 100, 140]) {
    const root = await mkdtemp(resolve(".devpilot-simple-pty-"));
    const eventLogPath = join(root, "events.jsonl");
    const dispatchEventLogPath = join(root, "manual-events.jsonl");
    const requestLogPath = join(root, "requests.jsonl");
    const descriptorPath = join(root, "descriptor.json");
    const role = width === 100 ? "review-handler" : "reviewer";
    const liveEvents = (["reviewer", "review-handler"] as const).flatMap((agent) =>
      ["agent.started", "agent.heartbeat"].map((type, index) => {
        const value = JSON.parse(event(agent, `simple-${agent}`, index + 1, type, { repository: "simple-live" }));
        return JSON.stringify({ ...value, pullRequestId: 0, timestamp: new Date().toISOString() });
      }));
    const contents = fixtureLines() + liveEvents.join("\n") + "\n";
    try {
      await writeFile(eventLogPath, contents);
      await writeFile(descriptorPath, JSON.stringify({
        requestLogPath, dispatchEventLogPath, simpleFlow: true, role,
      }));
      for (let launch = 0; launch < 2; launch++) {
        const screen = new TerminalScreen();
        screen.resize(width, 36);
        let revision = 0;
        let raw = "";
        let exited: PtyExit | undefined;
        let resolveExit!: (result: PtyExit) => void;
        const exit = new Promise<PtyExit>((resolve) => { resolveExit = resolve; });
        const terminal = spawn(resolve("node_modules", "bun", "bin", "bun.exe"), [
          "--conditions=browser", resolve("dist", "src", "index.js"),
          "--state-dir", root, "--event-log", eventLogPath, "--view-state-dir", join(root, "display"),
          "--launch-mode", "operational", "--broker-executable", resolvePowerShellPath(),
          "--broker-script", reviewerWideningBrokerScript(), "--broker-descriptor", descriptorPath,
        ], { name: "xterm-256color", cols: width, rows: 36, cwd: resolve("."), env: environment() });
        const output = terminal.onData((data) => {
          raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
          screen.write(data);
          revision++;
        });
        const subscription = terminal.onExit((result) => { exited = result; resolveExit(result); });
        const context = (message: string) => `${message} at ${width} columns, launch ${launch}\n${screen.text()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`;
        async function wait(expected: string | RegExp, start = 0): Promise<void> {
          const deadline = Date.now() + WAIT_TIMEOUT_MS;
          while (!exited && Date.now() < deadline) {
            const text = screen.text();
            if (revision >= start && (typeof expected === "string" ? text.includes(expected) : expected.test(text))) return;
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
          assert.fail(context(`Missing ${expected}`));
        }
        async function send(bytes: string, expected: string | RegExp): Promise<void> {
          const start = revision + 1;
          terminal.write(bytes);
          await wait(expected, start);
        }
        async function finish(): Promise<PtyExit> {
          let timeout: NodeJS.Timeout | undefined;
          try {
            return await Promise.race([exit, new Promise<never>((_, reject) => {
              timeout = setTimeout(() => reject(new Error(context("Dashboard did not exit"))), 15_000);
            })]);
          } finally { if (timeout) clearTimeout(timeout); }
        }
        async function simpleMain(): Promise<void> {
          await wait(SIMPLE_MAIN_HINT);
          await wait("LIVE AGENTS");
          await wait("Reviewer | No PR selected");
          await wait("Review Handler | No PR selected");
          assert.doesNotMatch(screen.text(), /\bINSPECTOR\b|\bFOCUS\b|\bPID\b|\bINSTANCES\b|\bRAW STREAM\b/,
            context("Simple main must not expose Advanced chrome"));
        }
        try {
          await wait("DEVPILOT OPERATIONS");
          await wait("OPERATIONAL");
          await simpleMain();
          if (launch === 0) {
            await send("h", "h Live | a Advanced | q Quit");
            await wait("Both agents | PR #104");
            await wait("ConPTY live flow");
            await send("\r", "Esc Back");
            await wait("DETAILS");
            await wait("Author: Ada");
            await wait("Reviewer: reviewed");
            await wait("Review Handler: handled");
            await send("\x1b", "Enter Details");
            await wait("Both agents | PR #104");
            assert.doesNotMatch(screen.text(), /\bDETAILS\b|\bAuthor: Ada\b/);

            await send("a", "Live only 2");
            await wait("INSTANCES 2");
            await send("\t", "Role filter changed");
            await wait("Live only 1");
            await send("F", "View filter changed to History");
            await wait("PR HISTORY 1");
            await send("a", SIMPLE_MAIN_HINT);
            await simpleMain(); // Both live roles must return after the Advanced History/role filters.

            await send("m", "PR ID: (blank)");
            if (role === "review-handler") await send("\t", "Agent: Review Handler");
            await send("104\r", /^[ \u2502]*NOT STARTED \/ READY TO START[ \u2502]*$/m);
            await wait("ConPTY widening flow");
            await wait(role === "reviewer" ? "Finding comments" : "Code pushes");
            assert.deepEqual(await readRequestOperations(requestLogPath), ["profile-current", "describe"],
              "The first Enter must only resolve and preview; it must not dispatch");
            await send("\r", /^[ \u2502]*STARTING[ \u2502]*$/m);
            await wait(/^[ \u2502]*STARTED[ \u2502]*$/m);
            await wait("Waiting for first progress");
            assert.doesNotMatch(screen.text(), /\bChild PID\b|\bFOCUS\b|\bINSPECTOR\b/);
            assert.equal((await readRequestOperations(requestLogPath)).filter((operation) => operation === "dispatch").length, 1,
              "The second Enter must start exactly one agent");
            await send("c", /^[ \u2502]*CANCELLING\.\.\.[ \u2502]*$/m);
            await wait(/^[ \u2502]*CANCELLED[ \u2502]*$/m);
            await send("\r", SIMPLE_MAIN_HINT);
            await simpleMain();

            // Quit in Advanced with non-default filters; the next process must still start in Simple.
            await send("a", "Live only 2");
            await send("\t", "Role filter changed");
            await wait("Live only 1");
            await send("F", "View filter changed to History");
            await wait("PR HISTORY 1");
          }
          terminal.write("q");
          const result = await finish();
          assert.equal(result.exitCode, 0, context("Fixture dashboard must quit cleanly"));
          assert.equal(result.signal ?? 0, 0);
          assert.equal(await readFile(eventLogPath, "utf8"), contents);
        } finally {
          try {
            if (!exited) { terminal.kill(); await finish(); }
            assert.ok(exited, "Owned dashboard must terminate before cleanup");
            assert.doesNotMatch(stripVTControlCharacters(raw), /AttachConsole failed|conpty_console_list_agent/i);
          } finally {
            disposeConptyOutputWorker(terminal);
            output.dispose();
            subscription.dispose();
          }
        }
      }
      assert.deepEqual(await readRequestOperations(requestLogPath),
        ["profile-current", "describe", "dispatch", "cancel", "shutdown", "shutdown"]);
      const requests = (await readFile(requestLogPath, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
      const dispatched = requests.filter((request) => request.operation === "dispatch");
      assert.equal(dispatched[0]?.role, role);
      assert.equal(dispatched[0]?.operatorPrompt, "");
    } finally { await rm(root, { recursive: true, force: true }); }
  }
});

test("real ConPTY Auto shows both 15-minute agents and Scan now is one honest main-view request", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 120_000,
}, async () => {
  for (const { width, automationFlow } of [
    { width: 70, automationFlow: true }, { width: 140, automationFlow: true }, { width: 70, automationFlow: false },
  ]) {
    const root = await mkdtemp(resolve(".devpilot-auto-scan-pty-"));
    const requestLogPath = join(root, "requests.jsonl");
    const eventLogPath = join(root, "events.jsonl");
    const descriptorPath = join(root, "descriptor.json");
    const screen = new TerminalScreen();
    screen.resize(width, 36);
    let revision = 0;
    let raw = "";
    let terminal: IPty | undefined;
    let exited: PtyExit | undefined;
    let output: IDisposable | undefined;
    let subscription: IDisposable | undefined;
    let resolveExit!: (result: PtyExit) => void;
    const exit = new Promise<PtyExit>((resolve) => { resolveExit = resolve; });
    const context = (message: string) => `${message} (${width} columns, automation ${automationFlow})\n${screen.text()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`;
    async function wait(expected: string | RegExp, start = 0): Promise<void> {
      const deadline = Date.now() + WAIT_TIMEOUT_MS;
      while (!exited && Date.now() < deadline) {
        const text = screen.text();
        if (revision >= start && (typeof expected === "string" ? text.includes(expected) : expected.test(text))) return;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      assert.fail(context(`Missing ${expected}`));
    }
    async function send(bytes: string, expected: string | RegExp): Promise<void> {
      assert.ok(terminal, "The isolated dashboard must be running");
      const start = revision + 1;
      terminal.write(bytes);
      await wait(expected, start);
    }
    async function finish(): Promise<PtyExit> {
      let timeout: NodeJS.Timeout | undefined;
      try {
        return await Promise.race([exit, new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(new Error(context("Dashboard did not exit"))), 15_000);
        })]);
      } finally { if (timeout) clearTimeout(timeout); }
    }
    async function assertScanCount(expected: number): Promise<void> {
      const requests = await readBrokerRequests(requestLogPath);
      const scans = requests.filter((request) => request.operation === "scan-now");
      assert.equal(scans.length, expected, context("Unexpected Scan now request count"));
      for (const request of scans) {
        assert.deepEqual(request, { schemaVersion: 1, requestId: request.requestId, operation: "scan-now" });
      }
    }
    try {
      await writeFile(eventLogPath, "");
      await writeFile(requestLogPath, "");
      await writeFile(descriptorPath, JSON.stringify({
        requestLogPath, dispatchEventLogPath: join(root, "manual-events.jsonl"),
        simpleFlow: true, role: "reviewer", automationFlow, automationManualPriorityAfterFirst: true,
      }));
      terminal = spawn(resolve("node_modules", "bun", "bin", "bun.exe"), [
        "--conditions=browser", resolve("dist", "src", "index.js"),
        "--state-dir", root, "--event-log", eventLogPath, "--view-state-dir", join(root, "display"),
        "--launch-mode", "operational", "--broker-executable", resolvePowerShellPath(),
        "--broker-script", reviewerWideningBrokerScript(), "--broker-descriptor", descriptorPath,
      ], { name: "xterm-256color", cols: width, rows: 36, cwd: resolve("."), env: environment() });
      output = terminal.onData((data) => { raw = (raw + data).slice(-MAX_CAPTURE_CHARS); screen.write(data); revision++; });
      subscription = terminal.onExit((result) => { exited = result; resolveExit(result); });
      await wait("LIVE AGENTS");
      const statusDeadline = Date.now() + WAIT_TIMEOUT_MS;
      while (!(await readBrokerRequests(requestLogPath)).some((request) => request.operation === "get-automation-status")) {
        assert.ok(!exited && Date.now() < statusDeadline, context("Mount must query automation status"));
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      await assertScanCount(0);
      if (automationFlow) {
        // Assert the compact status semantics without fixing its complete wording or separators.
        await wait(/\bAuto\b/i);
        await wait(/\bBoth\b/i);
        await wait(/\b15m\b/i);
        await wait("r Scan now");
        if (width === 140) {
          await send("a", "INSTANCES");
          await wait("r Scan now");
        }
        terminal.write("r" + "\x1b[114;1:2u".repeat(8) + "r");
        await wait("Reviewer wake requested");
        await wait("Handler already working");
        await assertScanCount(1);
        assert.doesNotMatch(screen.text(), /STARTED \/ RUNNING|Child PID/,
          "A scan wake request must not be presented as an accepted model/agent start");
        terminal.write("\x1b[114;1:2u".repeat(3) + "\x1b[114;1:3u");
        await new Promise((resolve) => setTimeout(resolve, 250));
        await assertScanCount(1);
        assert.deepEqual(await readRequestOperations(requestLogPath), ["scan-now"],
          "r needs no d/y/Enter confirmation and must not dispatch, cancel or queue work");

        if (width === 140) {
          await send("F", "View filter changed to History");
          await send("/r", "filter: r");
          await assertScanCount(1);
          terminal.write("\x1b");
          await new Promise((resolve) => setTimeout(resolve, 100));
          await send("a", "LIVE AGENTS");
          await send("a", "INSTANCES");
        }
        await send("m", "PR ID: (blank)");
        await send("104\r", "NOT STARTED / READY TO START");
        await send("p", "Optional instructions");
        await send("r", /^[ \u2502]*r[ \u2502]*$/m);
        await assertScanCount(1);
        assert.deepEqual(await readRequestOperations(requestLogPath), ["scan-now", "profile-current", "describe"],
          "Manual prompt input r is text, not an automation command");
        await send("\x1b", width === 140 ? "INSTANCES" : "LIVE AGENTS");
        await wait("r Scan now");
        await send("r", "Reviewer manual priority");
        await wait("Handler already working");
        await assertScanCount(2);
        assert.deepEqual(await readRequestOperations(requestLogPath),
          ["scan-now", "profile-current", "describe", "scan-now"],
          "Manual priority and active work must not produce cancellation, dispatch or an extra queued scan");
      } else {
        await wait("Auto: unavailable");
        await new Promise((resolve) => setTimeout(resolve, 250));
        assert.doesNotMatch(screen.text(), /r Scan now/);
        terminal.write("r\x1b[114;1:2u");
        await new Promise((resolve) => setTimeout(resolve, 250));
        await assertScanCount(0);
        assert.deepEqual(await readRequestOperations(requestLogPath), [],
          "An unavailable legacy launcher must never receive a scan wake");
      }
      terminal.write("q");
      const result = await finish();
      assert.equal(result.exitCode, 0, context("Fixture dashboard must quit cleanly"));
      assert.equal(result.signal ?? 0, 0);
      await assertScanCount(automationFlow ? 2 : 0);
      const polls = (await readBrokerRequests(requestLogPath)).filter((request) => request.operation === "get-automation-status");
      assert.ok(polls.length >= 1);
      for (const request of polls) {
        assert.deepEqual(request, { schemaVersion: 1, requestId: request.requestId, operation: "get-automation-status" });
      }
      assert.deepEqual(await readRequestOperations(requestLogPath),
        automationFlow ? ["scan-now", "profile-current", "describe", "scan-now", "shutdown"] : ["shutdown"]);
      assert.equal(await readFile(eventLogPath, "utf8"), "");
    } finally {
      try {
        if (terminal && !exited) { terminal.kill(); await finish(); }
        if (terminal) assert.ok(exited, "Owned fixture dashboard must terminate before cleanup");
        assert.doesNotMatch(raw, /AttachConsole failed|conpty_console_list_agent/i);
      } finally {
        if (terminal) disposeConptyOutputWorker(terminal);
        output?.dispose();
        subscription?.dispose();
        await rm(root, { recursive: true, force: true });
      }
    }
  }
});

function reviewerWideningBrokerScript(): string {
  return resolve("test\\fixtures\\reviewer-widening-broker.ps1");
}

async function busyBrokerSource(): Promise<string> {
  const source = await readFile(reviewerWideningBrokerScript(), "utf8");
  const loop = "$accepting = $true";
  assert.equal(source.split(loop).length, 2, "The shared fixture must have one protocol loop");
  // Reuse its identities, capability responses and fake dispatch/cancel functions.
  return source.slice(0, source.indexOf(loop)) + String.raw`
$prepareCount = 0
$prepared = $null
$pendingQueue = $null
$lastDispatch = $null
$queueId = '77777777-7777-4777-8777-777777777777'
function Emit([object]$response) {
  [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 10))
}
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $request = $line | ConvertFrom-Json
  Append-Log $request
  switch ($request.operation) {
    'get-automation-status' { Emit (Automation-Status-Response $request | ConvertFrom-Json) }
    { $_ -in @('profile-current', 'describe') } {
      $response = Describe-Response $request | ConvertFrom-Json
      $response | Add-Member -NotePropertyName scheduling -NotePropertyValue @{version=1;scope='current-launcher'}
      Emit $response
    }
    'dispatch' {
      $lastDispatch = $request
      Emit @{schemaVersion=1;requestId=$request.requestId;operation='rejected'
        code=$descriptor.busyCode;detail='The current launcher is reviewing PR #114.'}
    }
    'prepare-run' {
      if ($null -eq $lastDispatch) { throw 'Preparation must follow the explicit busy dispatch attempt.' }
      if ($request.repositoryKey -ne $repositoryIdentity.key -or $request.pullRequestId -ne 104 -or
          $request.role -ne 'reviewer' -or $request.mode -notin @('replace', 'next') -or
          $request.capabilityPolicyDigest -ne $baselineDigest -or $request.prStateFingerprint -ne $prStateFingerprint) {
        throw 'Preparation changed the verified target.'
      }
      $prepareCount++
      $prepared = @{schemaVersion=1;requestId=$request.requestId;operation='run-prepared'
        schedulingVersion=1;scope='current-launcher';confirmationToken=(('a'*47) + $prepareCount.ToString('x'))
        expiresAtUtc=[DateTime]::UtcNow.AddMinutes(2).ToString('o');repositoryKey=$repositoryIdentity.key
        pullRequestId=104;role='reviewer';mode=$request.mode
        conflict=@{kind='automatic';pullRequestId=(113 + $prepareCount)
          workId=('33333333-3333-4333-8333-{0:D12}' -f $prepareCount)
          generation=('44444444-4444-4444-8444-{0:D12}' -f $prepareCount)}
      }
      Emit $prepared
    }
    'confirm-run' {
      if ($null -eq $prepared -or $request.confirmationToken -ne $prepared.confirmationToken -or
          $request.expectedWorkId -ne $prepared.conflict.workId -or
          $request.expectedGeneration -ne $prepared.conflict.generation) {
        throw 'Confirmation reused an obsolete work generation or choice.'
      }
      $pendingQueue = $queueId
      $queued = @{schemaVersion=1;requestId=$request.requestId;operation='run-queued'
        schedulingVersion=1;queueId=$queueId;mode=$prepared.mode}
      $prepared = $null
      if ($descriptor.busyFlow -eq 'queued') {
        Emit $queued
        Emit @{schemaVersion=1;requestId=$request.requestId;operation='run-progress'
          schedulingVersion=1;queueId=$queueId;state='queued';code=''}
      } else {
        $messages = [System.Collections.Generic.List[string]]::new()
        $messages.Add(($queued | ConvertTo-Json -Compress))
        foreach ($state in @('queued', 'quiescing', 'waiting-authority', 'revalidating')) {
          $messages.Add((@{schemaVersion=1;requestId=$request.requestId;operation='run-progress'
            schedulingVersion=1;queueId=$queueId;state=$state;code=''
          } | ConvertTo-Json -Compress))
        }
        $accepted = Dispatch-Response $lastDispatch | ConvertFrom-Json
        $accepted.requestId = $request.requestId
        $accepted | Add-Member -NotePropertyName queueId -NotePropertyValue $queueId
        $messages.Add(($accepted | ConvertTo-Json -Compress -Depth 10))
        $pendingQueue = $null
        # One write stresses acceptance arriving before the confirm-run continuation.
        [Console]::Out.WriteLine(($messages -join [Environment]::NewLine))
      }
    }
    'cancel-queued' {
      if ($null -eq $pendingQueue -or $request.queueId -ne $pendingQueue) { throw 'Only the pending queue may be cancelled.' }
      $pendingQueue = $null
      Emit @{schemaVersion=1;requestId=$request.requestId;operation='queue-cancelled';schedulingVersion=1;queueId=$request.queueId}
      Emit @{schemaVersion=1;requestId=$request.requestId;operation='run-progress'
        schedulingVersion=1;queueId=$request.queueId;state='resumed';code=''}
    }
    'cancel' {
      Emit (Cancel-Dispatch $request | ConvertFrom-Json)
      Emit @{schemaVersion=1;requestId=$request.requestId;operation='run-progress'
        schedulingVersion=1;queueId=$queueId;state='resumed';code=''}
    }
    'shutdown' {
      Emit @{schemaVersion=1;requestId=$request.requestId;operation='shutdown-complete'}
      return
    }
    default { throw "Unexpected busy fixture operation $($request.operation)" }
  }
}
`;
}

interface BusyPty {
  readonly dispatchId: string;
  wait(expected: string | RegExp, start?: number): Promise<void>;
  send(bytes: string, expected: string | RegExp): Promise<void>;
  write(bytes: string): void;
  text(): string;
  requests(): Promise<Record<string, unknown>[]>;
}

async function withBusyPty(
  mode: "simple" | "advanced",
  busyFlow: "queued" | "accepted",
  action: (fixture: BusyPty) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(resolve(".devpilot-busy-pty-"));
  const dispatchId = randomUUID();
  const requestLogPath = join(root, "requests.jsonl");
  const descriptorPath = join(root, "descriptor.json");
  const scriptPath = join(root, "broker.ps1");
  const eventLogPath = join(root, "events.jsonl");
  const width = mode === "simple" ? 70 : 140;
  const screen = new TerminalScreen();
  screen.resize(width, 36);
  let revision = 0;
  let raw = "";
  let terminal: IPty | undefined;
  let exited: PtyExit | undefined;
  let output: IDisposable | undefined;
  let subscription: IDisposable | undefined;
  let resolveExit!: (result: PtyExit) => void;
  const exit = new Promise<PtyExit>((resolve) => { resolveExit = resolve; });
  const context = (message: string) => `${message} (${mode}, ${busyFlow}, ${width} columns)\n${screen.text()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`;
  async function wait(expected: string | RegExp, start = 0): Promise<void> {
    const deadline = Date.now() + WAIT_TIMEOUT_MS;
    while (!exited && Date.now() < deadline) {
      const text = screen.text();
      if (revision >= start && (typeof expected === "string" ? text.includes(expected) : expected.test(text))) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.fail(context(`Missing ${expected}`));
  }
  function write(bytes: string): void {
    assert.ok(terminal, "The isolated dashboard must be running");
    terminal.write(bytes);
  }
  async function send(bytes: string, expected: string | RegExp): Promise<void> {
    const start = revision + 1;
    write(bytes);
    await wait(expected, start);
  }
  async function finish(): Promise<PtyExit> {
    let timeout: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([exit, new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(context("Dashboard did not exit"))), 15_000);
      })]);
    } finally { if (timeout) clearTimeout(timeout); }
  }
  async function requests(): Promise<Record<string, unknown>[]> {
    return readInteractionRequests(requestLogPath);
  }
  try {
    await writeFile(eventLogPath, "");
    await writeFile(requestLogPath, "");
    await writeFile(scriptPath, await busyBrokerSource());
    await writeFile(descriptorPath, JSON.stringify({
      requestLogPath, dispatchId, dispatchEventLogPath: join(root, "manual-events.jsonl"), simpleFlow: true,
      role: "reviewer", busyFlow, busyCode: busyFlow === "queued" ? "state-contended" : "already-running",
    }));
    terminal = spawn(resolve("node_modules", "bun", "bin", "bun.exe"), [
      "--conditions=browser", resolve("dist", "src", "index.js"),
      "--state-dir", root, "--event-log", eventLogPath, "--view-state-dir", join(root, "display"),
      "--launch-mode", "operational", "--broker-executable", resolvePowerShellPath(),
      "--broker-script", scriptPath, "--broker-descriptor", descriptorPath,
    ], { name: "xterm-256color", cols: width, rows: 36, cwd: resolve("."), env: environment() });
    output = terminal.onData((data) => { raw = (raw + data).slice(-MAX_CAPTURE_CHARS); screen.write(data); revision++; });
    subscription = terminal.onExit((result) => { exited = result; resolveExit(result); });
    await wait(SIMPLE_MAIN_HINT);
    if (mode === "advanced") await send("a", "INSTANCES");
    await action({ dispatchId, wait, send, write, text: () => screen.text(), requests });
    write("q");
    const result = await finish();
    assert.equal(result.exitCode, 0, context("Fixture dashboard must quit cleanly"));
    assert.equal(result.signal ?? 0, 0);
    assert.equal((await requests()).at(-1)?.operation, "shutdown");
    assert.equal(await readFile(eventLogPath, "utf8"), "");
  } finally {
    try {
      if (terminal && !exited) { terminal.kill(); await finish(); }
      if (terminal) assert.ok(exited, "Only the owned fixture dashboard may be cleaned up");
      assert.doesNotMatch(raw, /AttachConsole failed|conpty_console_list_agent/i);
    } finally {
      if (terminal) disposeConptyOutputWorker(terminal);
      output?.dispose();
      subscription?.dispose();
      await rm(root, { recursive: true, force: true });
    }
  }
}

async function assertBusyRequestsUnchanged(fixture: BusyPty, before?: Record<string, unknown>[]): Promise<void> {
  const baseline = before ?? await fixture.requests();
  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.deepEqual(await fixture.requests(), baseline, "Buffered/repeated input must not issue another broker request");
}

async function waitForBusyPreparations(fixture: BusyPty, modes: string[]): Promise<void> {
  const deadline = Date.now() + WAIT_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const requests = await fixture.requests();
    assert.equal(requests.filter((request) => request.operation === "confirm-run").length, 0,
      "Changing choices must only prepare, never confirm");
    const preparations = requests.filter((request) => request.operation === "prepare-run");
    if (preparations.length >= modes.length) {
      assert.deepEqual(preparations.map((request) => request.mode), modes);
      const label = modes.at(-1) === "replace" ? "Replace / run now" : "Run next";
      await fixture.wait(`NOT STARTED | Reviewer PR #${113 + modes.length} is busy`);
      await fixture.wait(`> ${label}`);
      await fixture.wait(`Enter: ${label} | Esc: Back | q: quit`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.fail(`Missing preparation modes ${modes.join(", ")}\n${fixture.text()}`);
}

async function enterBusyPrompt(fixture: BusyPty): Promise<void> {
  await fixture.send("m", "PR ID: (blank)");
  await fixture.send("104\r\r", "NOT STARTED / READY TO START");
  assert.deepEqual((await fixture.requests()).map((request) => request.operation), ["profile-current", "describe"]);
  await fixture.send("\r\r\x1b[13;1:2u", "> Replace / run now");
  await fixture.wait("Run next");
  await fixture.wait("Back");
  await waitForBusyPreparations(fixture, ["replace"]);
  assert.deepEqual((await fixture.requests()).map((request) => request.operation),
    ["profile-current", "describe", "dispatch", "prepare-run"],
    "A busy dispatch must automatically prepare the default Replace choice, without confirming it");
  const beforeRepeat = await fixture.requests();
  fixture.write("\x1b[13;1:2u");
  await assertBusyRequestsUnchanged(fixture, beforeRepeat);
}

function assertConfirmedLatestBusyPreparation(requests: Record<string, unknown>[]): void {
  const preparations = requests.filter((request) => request.operation === "prepare-run");
  const confirmations = requests.filter((request) => request.operation === "confirm-run");
  assert.equal(confirmations.length, 1, "One fresh Enter must confirm exactly once");
  const generation = String(preparations.length).padStart(12, "0");
  assert.deepEqual(confirmations[0], {
    schemaVersion: 1, requestId: confirmations[0]?.requestId, operation: "confirm-run",
    confirmationToken: "a".repeat(47) + preparations.length.toString(16),
    expectedWorkId: `33333333-3333-4333-8333-${generation}`,
    expectedGeneration: `44444444-4444-4444-8444-${generation}`,
  }, "Confirmation must bind the latest choice and exact current work generation");
  assert.equal(requests.filter((request) => request.operation === "dispatch").length, 1,
    "Scheduling must not retry the consumed dispatch draft");
  for (const preparation of preparations) {
    assert.equal(preparation.repositoryKey, "v1:github:10400000000000001");
    assert.equal(preparation.pullRequestId, 104);
    assert.equal(preparation.role, "reviewer");
    assert.equal(preparation.operatorPrompt, "");
    assert.equal("dispatchDraftId" in preparation, false);
  }
}

test("real ConPTY Simple busy Back is inert and Run next cancels only its pending queue at 70 columns", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 90_000,
}, async () => {
  await withBusyPty("simple", "queued", async (fixture) => {
    await enterBusyPrompt(fixture);
    const before = await fixture.requests();
    await fixture.send("\x1b", SIMPLE_MAIN_HINT);
    await assertBusyRequestsUnchanged(fixture, before);
    assert.deepEqual(await fixture.requests(), before, "Back must not confirm or cancel existing work");
  });
  await withBusyPty("simple", "queued", async (fixture) => {
    await enterBusyPrompt(fixture);
    fixture.write("\t");
    await waitForBusyPreparations(fixture, ["replace", "next"]);
    fixture.write("\x1b[A");
    await waitForBusyPreparations(fixture, ["replace", "next", "replace"]);
    fixture.write("\x1b[B");
    await waitForBusyPreparations(fixture, ["replace", "next", "replace", "next"]);
    await fixture.wait("Run next");
    const beforeRepeat = await fixture.requests();
    fixture.write("\x1b[13;1:2u");
    await assertBusyRequestsUnchanged(fixture, beforeRepeat);
    await fixture.send("\r", "QUEUED / NOT STARTED");
    await fixture.wait("c/Esc: cancel queued request | q: quit and stop");
    assertConfirmedLatestBusyPreparation(await fixture.requests());
    assert.doesNotMatch(fixture.text(), /\bChild PID\b|\bFOCUS\b|\bINSPECTOR\b/);
    await fixture.send("c", "CANCELLED / NOT STARTED");
    await fixture.wait("Automatic work resumed.");
    const requests = await fixture.requests();
    assertConfirmedLatestBusyPreparation(requests);
    assert.deepEqual(requests.filter((request) => request.operation === "cancel-queued").map((request) => request.queueId),
      ["77777777-7777-4777-8777-777777777777"]);
    assert.equal(requests.filter((request) => request.operation === "cancel").length, 0,
      "Cancelling Run next must not stop the currently running automatic work");
    assert.deepEqual(requests.map((request) => request.operation), [
      "profile-current", "describe", "dispatch", "prepare-run", "prepare-run", "prepare-run", "prepare-run",
      "confirm-run", "cancel-queued",
    ]);
  });
});

test("real ConPTY Simple and Advanced route same-write busy queue progress and acceptance to the running agent", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 90_000,
}, async () => {
  for (const mode of ["simple", "advanced"] as const) {
    await withBusyPty(mode, "accepted", async (fixture) => {
      await enterBusyPrompt(fixture);
      const running = /^[ \u2502]*STARTED[ \u2502]*$/m;
      await fixture.send("\r", running);
      await fixture.wait("Waiting for first progress");
      assertConfirmedLatestBusyPreparation(await fixture.requests());
      await assertBusyRequestsUnchanged(fixture);
      await fixture.wait(running);
      if (mode === "simple") assert.doesNotMatch(fixture.text(), /\bChild PID\b|\bFOCUS\b|\bINSPECTOR\b/);
      await fixture.send("c", "CANCELLED");
      await fixture.wait("Automatic work resumed.");
      const requests = await fixture.requests();
      assert.deepEqual(requests.map((request) => request.operation),
        ["profile-current", "describe", "dispatch", "prepare-run", "confirm-run", "cancel"]);
      assert.equal(requests.find((request) => request.operation === "cancel")?.dispatchId,
        fixture.dispatchId);
      await fixture.send("\r", mode === "simple" ? SIMPLE_MAIN_HINT : "INSTANCES");
    });
  }
});

/*
param([string]$DescriptorPath)
$descriptor = Get-Content -Raw -Path $DescriptorPath | ConvertFrom-Json
$requestLogPath = $descriptor.requestLogPath
$dispatchEventLogPath = $descriptor.dispatchEventLogPath
if ($dispatchEventLogPath) {
  New-Item -ItemType File -Force -Path $dispatchEventLogPath | Out-Null
}
$repositoryIdentity = @{
  schemaVersion = 1
  provider = 'GitHub'
  repositoryId = '10400000000000001'
  organization = 'devpilot'
  project = ''
  repositoryName = 'operations-dashboard'
  slug = 'devpilot/operations-dashboard'
  key = 'v1:github:10400000000000001'
  verifiedAtUtc = '2026-09-03T15:00:00Z'
  verified = $true
  dispatchEligible = $true
}
$prSnapshot = @{
  schemaVersion = 1
  pullRequestId = 104
  sourceCommit = ('a' * 40)
  sourceRef = 'joerob/issue-105-pr2'
  targetRef = 'main'
  active = $true
  draft = $false
  author = 'Ada'
  title = 'ConPTY widening flow'
}
$baseCapabilities = @('EnableSummaryComment', 'EnableThreadReplies', 'EnableFindingComments')
$baseMandatoryDenies = @('EnableApprovalVote')
$delegableAvailable = @('EnableApprovalVote')
$absoluteDenies = @('EnableAutoComplete')
$allowedManualCapabilities = @('EnableSummaryComment', 'EnableThreadReplies', 'EnableFindingComments')
$baselineDigest = ('1' * 64)
$widenedDigest = ('2' * 64)
$prStateFingerprint = ('3' * 64)
$dispatchDraftId = '11111111-1111-1111-1111-111111111111'
$dispatchId = '22222222-2222-2222-2222-222222222222'
$previewChallenge = ('a' * 48)
$summaryChallenge = ('b' * 48)
$previewExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(10).ToString('o')
$summaryExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(11).ToString('o')
$grantExpiresAtUtc = [DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeSeconds()
$previewDiff = @{
  addedCapabilities = @('EnableApprovalVote')
  removedDenies = @('EnableApprovalVote')
  pairedCapability = 'EnableFindingComments'
  pairedCapabilityActive = $true
}
$wideningStage = $null
$wideningGeneration = 0
$dispatchActive = $false
function Append-Log([object]$request) {
  [System.IO.File]::AppendAllText($requestLogPath, (($request | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine))
}
function Provenance([bool]$widened) {
  if ($widened) {
    return [ordered]@{
      EnableFindingComments = 'repo-worktree'
      EnableSummaryComment = 'machine'
      EnableThreadReplies = 'user'
      EnableApprovalVote = 'repo-worktree'
    }
  }
  return [ordered]@{
    EnableFindingComments = 'repo-worktree'
    EnableSummaryComment = 'machine'
    EnableThreadReplies = 'user'
    EnableApprovalVote = 'operational-default'
  }
}
function Current-Effect([bool]$widened) {
  return @{
    capabilities = if ($widened) { @('EnableSummaryComment', 'EnableThreadReplies', 'EnableFindingComments', 'EnableApprovalVote') } else { @($baseCapabilities) }
    mandatoryDenies = if ($widened) { @() } else { @($baseMandatoryDenies) }
    provenance = Provenance $widened
  }
}
function Describe-Response([object]$request) {
  $effect = Current-Effect $false
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'capability-summary'
    role = $request.role
    dispatchDraftId = $dispatchDraftId
    repositoryIdentity = $repositoryIdentity
    prSnapshot = $prSnapshot
    capabilityPolicyDigest = $baselineDigest
    prStateFingerprint = $prStateFingerprint
    capabilities = $effect.capabilities
    mandatoryDenies = $effect.mandatoryDenies
    dynamicConstraints = @()
    absoluteDenies = @($absoluteDenies)
    allowedManualCapabilities = @($allowedManualCapabilities)
    delegableAvailable = @($delegableAvailable)
    provenance = $effect.provenance
    killSwitchActive = $false
    killSwitchExpiresAtUtc = $null
  } | ConvertTo-Json -Compress -Depth 10
}
function Describe-Widening([object]$request) {
  if ($request.capability -ne 'EnableApprovalVote') { throw 'unexpected widening capability' }
  if ($script:wideningStage -eq 'minted') { throw 'widening already minted' }
  $script:wideningStage = 'previewed'
  $script:wideningGeneration = 1
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-preview'
    state = 'previewed'
    dispatchDraftId = $dispatchDraftId
    capability = $request.capability
    challenge = $previewChallenge
    effectiveDiff = $previewDiff
    expiresAtUtc = $previewExpiresAtUtc
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Confirm-Widening-Preview([object]$request) {
  if ($script:wideningStage -ne 'previewed' -or $request.capability -ne 'EnableApprovalVote' -or $request.challenge -ne $previewChallenge) {
    throw 'unexpected widening preview confirmation'
  }
  $script:wideningStage = 'summary'
  $script:wideningGeneration++
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-summary'
    state = 'awaiting-final-confirmation'
    dispatchDraftId = $dispatchDraftId
    capability = $request.capability
    challenge = $summaryChallenge
    effectiveDiff = $previewDiff
    expiresAtUtc = $summaryExpiresAtUtc
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Confirm-Widening-Mint([object]$request) {
  if ($script:wideningStage -ne 'summary' -or $request.capability -ne 'EnableApprovalVote' -or $request.challenge -ne $summaryChallenge) {
    throw 'unexpected widening mint confirmation'
  }
  $script:wideningStage = 'minted'
  $script:wideningGeneration++
  $effect = Current-Effect $true
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-minted'
    state = 'minted'
    dispatchDraftId = $dispatchDraftId
    capability = $request.capability
    capabilities = $effect.capabilities
    mandatoryDenies = $effect.mandatoryDenies
    capabilityPolicyDigest = $widenedDigest
    effectiveDiff = $previewDiff
    grantExpiresAtUtc = $grantExpiresAtUtc
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Cancel-Widening([object]$request) {
  if ($script:wideningStage -notin @('previewed', 'summary', 'minted')) {
    throw 'unexpected widening cancellation'
  }
  if ($request.generation -ne $script:wideningGeneration) {
    throw 'unexpected widening generation'
  }
  $script:wideningStage = $null
  $script:wideningGeneration++
  $effect = Current-Effect $false
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-cancelled'
    state = 'cancelled'
    dispatchDraftId = $dispatchDraftId
    capabilities = $effect.capabilities
    mandatoryDenies = $effect.mandatoryDenies
    capabilityPolicyDigest = $baselineDigest
    delegableAvailable = @($delegableAvailable)
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Dispatch-Response([object]$request) {
  if ($script:wideningStage -ne 'minted') { throw 'widening grant not minted' }
  if ($request.dispatchDraftId -ne $dispatchDraftId -or $request.capabilityPolicyDigest -ne $widenedDigest -or $request.prStateFingerprint -ne $prStateFingerprint) {
    throw 'dispatch bindings do not match the widened draft'
  }
  $script:dispatchActive = $true
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'accepted'
    dispatchId = $dispatchId
    repositoryIdentity = $repositoryIdentity
    pullRequestId = 104
    role = $request.role
    capabilityPolicyDigest = $widenedDigest
    prStateFingerprint = $prStateFingerprint
    childProcessId = 4242
    eventLogPath = $dispatchEventLogPath
  } | ConvertTo-Json -Compress -Depth 10
}
function Cancel-Dispatch([object]$request) {
  if (-not $script:dispatchActive) { throw 'dispatch is not active' }
  $script:dispatchActive = $false
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'cancelled'
    dispatchId = $request.dispatchId
    result = 'cooperatively'
    handleReleaseObserved = $true
  } | ConvertTo-Json -Compress -Depth 10
}
$accepting = $true
while ($accepting -and $null -ne ($line = [Console]::In.ReadLine())) {
  $request = $line | ConvertFrom-Json
  Append-Log $request
  switch ($request.operation) {
    'describe' { Write-Output (Describe-Response $request) }
    'describe-widening' { Write-Output (Describe-Widening $request) }
    'confirm-widening-preview' { Write-Output (Confirm-Widening-Preview $request) }
    'confirm-widening-mint' { Write-Output (Confirm-Widening-Mint $request) }
    'cancel-widening' { Write-Output (Cancel-Widening $request) }
    'dispatch' { Write-Output (Dispatch-Response $request) }
    'cancel' { Write-Output (Cancel-Dispatch $request) }
    'shutdown' {
      $accepting = $false
      Write-Output (@{
        schemaVersion = 1
        requestId = $request.requestId
        operation = 'shutdown-complete'
      } | ConvertTo-Json -Compress -Depth 10)
    }
    default { throw "unexpected operation $($request.operation)" }
  }
}
*/

async function readBrokerRequests(path: string): Promise<Record<string, unknown>[]> {
  const content = await readFile(path, "utf8");
  return content
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line): Record<string, unknown> => JSON.parse(line));
}

async function readInteractionRequests(path: string): Promise<Record<string, unknown>[]> {
  // Only background status polls are excluded; scan-now and every other request stay observable.
  return (await readBrokerRequests(path)).filter((request) => {
    if (request.operation !== "get-automation-status") return true;
    assert.deepEqual(Object.keys(request).sort(), ["operation", "requestId", "schemaVersion"]);
    assert.equal(request.schemaVersion, 1);
    assert.equal(typeof request.requestId, "string");
    return false;
  });
}

async function readRequestOperations(path: string): Promise<string[]> {
  return (await readInteractionRequests(path)).map((request) => {
    assert.ok(typeof request.operation === "string");
    return request.operation;
  });
}

function environment(): Record<string, string> {
  return Object.fromEntries(
    Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  );
}

function resolvePowerShellPath(): string {
  const lookups: Array<[string, string]> = process.platform === "win32"
    ? [["where.exe", "pwsh"], ["where.exe", "powershell.exe"], ["where.exe", "powershell"]]
    : [["which", "pwsh"], ["which", "powershell"]];
  for (const [tool, candidate] of lookups) {
    try {
      const output = execFileSync(tool, [candidate], { encoding: "utf8" });
      const resolved = output
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line.length > 0);
      if (resolved) return resolved;
    } catch {
      // Try the next candidate.
    }
  }
  throw new Error("PowerShell executable not found on PATH");
}

test("built dashboard accepts real ConPTY input and exits cleanly", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 60_000,
}, async () => {
  const dashboardRoot = resolve(".");
  const stateRoot = await mkdtemp(resolve(".devpilot-dashboard-pty-"));
  assert.ok(isAbsolute(stateRoot));
  assert.notEqual(resolve(stateRoot), dashboardRoot);

  const eventDirectory = join(stateRoot, "logs", "events", "reviewer");
  const eventPath = join(eventDirectory, "fixture.jsonl");
  const bunPath = resolve(dashboardRoot, "node_modules", "bun", "bin", "bun.exe");
  const entryPath = resolve(dashboardRoot, "dist", "src", "index.js");
  let terminal: IPty | undefined;
  let dataSubscription: IDisposable | undefined;
  let exitSubscription: IDisposable | undefined;
  let terminalColumns = 130;
  let terminalRows = 36;
  let revision = 0;
  let raw = "";
  const screen = new TerminalScreen();
  let exited: PtyExit | undefined;
  let resolveExit: ((exit: PtyExit) => void) | undefined;
  const exitPromise = new Promise<PtyExit>((resolvePromise) => {
    resolveExit = resolvePromise;
  });

  function visibleOutput(): string {
    return screen.text();
  }

  function failureContext(message: string): Error {
    return new Error(`${message}\n--- current terminal screen ---\n${visibleOutput()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`);
  }

  async function waitForVisible(expected: string, start = 0): Promise<void> {
    const deadline = Date.now() + WAIT_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (revision >= start && visibleOutput().includes(expected)) return;
      if (exited) throw failureContext(`dashboard exited before rendering ${JSON.stringify(expected)}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
    throw failureContext(`timed out waiting for ${JSON.stringify(expected)}`);
  }

  async function writeAndWait(bytes: string, expected: string): Promise<void> {
    assert.ok(terminal, "terminal must be running");
    const start = revision + 1;
    terminal.write(bytes);
    await waitForVisible(expected, start);
  }

  async function waitForExit(message: string): Promise<PtyExit> {
    let timeout: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        exitPromise,
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(failureContext(message)), EXIT_TIMEOUT_MS);
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  try {
    await access(bunPath);
    await access(entryPath);
    await mkdir(eventDirectory, { recursive: true });
    await writeFile(eventPath, fixtureLines(), "utf8");

    terminal = spawn(bunPath, ["--conditions=browser", entryPath, "--state-dir", stateRoot,
      "--view-state-dir", join(stateRoot, "display")], {
      name: "xterm-256color",
      cols: 130,
      rows: 36,
      cwd: dashboardRoot,
      env: environment(),
    });
    dataSubscription = terminal.onData((data) => {
      raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
      screen.write(data);
      revision++;
    });
    exitSubscription = terminal.onExit((eventExit) => {
      exited = eventExit;
      resolveExit?.(eventExit);
    });

    await waitForVisible(SIMPLE_MAIN_HINT);
    await writeAndWait("a", "FOCUS RAIL");
    await waitForVisible("DEVPILOT OPERATIONS");
    await waitForVisible("OBSERVE ONLY");
    await waitForVisible("LIVE ONLY");
    await writeAndWait("l", "View filter changed to Current session");
    await waitForVisible("ConPTY live flow");

    await writeAndWait("?", "HELP - OBSERVE MODE");
    await waitForVisible("Left / Right");
    await writeAndWait("\x1b", "Help closed");

    await writeAndWait("f", "View filter changed to History");
    await writeAndWait("F", "View filter changed to Current session");
    await writeAndWait("f", "View filter changed to History");
    await writeAndWait("\t", "HISTORY | REVIEWER");
    await writeAndWait("\t", "HISTORY | REVIEW-HANDLER");
    await writeAndWait("\t", "HISTORY | ALL");
    await writeAndWait("\x1b[Z", "HISTORY | REVIEW-HANDLER");
    await writeAndWait("\x1b[Z", "HISTORY | REVIEWER");
    await writeAndWait("m", "Observe-only launch: trusted manual broker is unavailable");

    await writeAndWait("i", "Inspector closed");
    await writeAndWait("i", "Inspector opened and focused");
    await writeAndWait("e", "RAW EVENTS - ALL");
    const scrollStart = revision + 1;
    terminal.write("\x1b[A".repeat(12));
    await waitForVisible("scroll marker 01", scrollStart);
    await writeAndWait("\x1b[C", "RAW EVENTS - WARNINGS");
    await writeAndWait("\x1b", "Events overlay closed");

    await writeAndWait("\x10", "DASHBOARD COMMANDS");
    await writeAndWait("\x1b", "Command palette closed");

    await writeAndWait("/missing\r", "PR HISTORY 0");
    assert.match(visibleOutput(), /filter: missing/);
    await writeAndWait("/\x7f\x7f\x7f\x7f\x7f\x7f\x7f\r", "> operations-dashboard PR #104");
    await writeAndWait("/cancelled", "filter: cancelled");
    terminal.write("\x1b");
    await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    terminal.write("104\r");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.write("x");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.write("X");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));

    assert.ok(terminal);
    let resizeStart = revision + 1;
    terminalColumns = 70;
    terminalRows = 24;
    screen.resize(terminalColumns, terminalRows);
    terminal.resize(terminalColumns, terminalRows);
    await waitForVisible("HISTORY | REVIEWER | FOCUS RAIL", resizeStart);
    resizeStart = revision + 1;
    terminalColumns = 130;
    terminalRows = 36;
    screen.resize(terminalColumns, terminalRows);
    terminal.resize(terminalColumns, terminalRows);
    await waitForVisible("HISTORY | REVIEWER | WIDE | FOCUS RAIL", resizeStart);

    await writeAndWait("s", "SETTINGS - EFFECTIVE CAPABILITY PROFILE");
    await waitForVisible("Unavailable: trusted manual broker is not connected (observe-only mode).");
    await writeAndWait("\x1b", "Effective profile settings closed");

    terminal.write("q");
    const result = await waitForExit("dashboard hung after quit input");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);
  } finally {
    try {
      if (terminal && !exited) {
        terminal.kill();
        await waitForExit("dashboard did not terminate after cleanup kill");
      }
      if (terminal) {
        assert.ok(exited, "node-pty must report child termination before cleanup completes");
        disposeConptyOutputWorker(terminal);
      }
      assert.doesNotMatch(
        stripVTControlCharacters(raw),
        /AttachConsole failed|conpty_console_list_agent/i,
        failureContext("node-pty helper failure was written to the terminal").message,
      );
    } finally {
      dataSubscription?.dispose();
      exitSubscription?.dispose();
      await rm(stateRoot, { recursive: true, force: true });
    }
  }
});

test("built dashboard exercises the PR3 settings editor through real ConPTY and leaves no broker residue", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 90_000,
}, async () => {
  const dashboardRoot = resolve(".");
  const stateRoot = await mkdtemp(join(tmpdir(), "devpilot-dashboard-pr3-pty-"));
  assert.ok(isAbsolute(stateRoot));
  assert.notEqual(resolve(stateRoot), dashboardRoot);

  const eventDirectory = join(stateRoot, "logs", "events", "reviewer");
  const eventPath = join(eventDirectory, "fixture.jsonl");
  const requestLogPath = join(stateRoot, "broker-requests.jsonl");
  const brokerScriptPath = join(stateRoot, "fake-broker.ps1");
  const brokerDescriptorPath = join(stateRoot, "broker-descriptor.json");
  const bunPath = resolve(dashboardRoot, "node_modules", "bun", "bin", "bun.exe");
  const entryPath = resolve(dashboardRoot, "dist", "src", "index.js");
  const powerShellPath = resolvePowerShellPath();
  let terminal: IPty | undefined;
  let dataSubscription: IDisposable | undefined;
  let exitSubscription: IDisposable | undefined;
  let revision = 0;
  let raw = "";
  const screen = new TerminalScreen();
  let exited: { exitCode: number; signal?: number } | undefined;
  let resolveExit: ((exit: { exitCode: number; signal?: number }) => void) | undefined;
  const exitPromise = new Promise<{ exitCode: number; signal?: number }>((resolvePromise) => {
    resolveExit = resolvePromise;
  });

  function visibleOutput(): string {
    return screen.text();
  }

  function failureContext(message: string): Error {
    return new Error(`${message}\n--- current terminal screen ---\n${visibleOutput()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`);
  }

  async function waitForVisible(expected: string, start = 0): Promise<void> {
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline) {
      if (revision >= start && visibleOutput().includes(expected)) return;
      if (exited) throw failureContext(`dashboard exited before rendering ${JSON.stringify(expected)}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
    throw failureContext(`timed out waiting for ${JSON.stringify(expected)}`);
  }

  async function writeAndWait(bytes: string, expected: string): Promise<void> {
    assert.ok(terminal, "terminal must be running");
    const start = revision + 1;
    terminal.write(bytes);
    await waitForVisible(expected, start);
  }

  async function waitForExit(message: string): Promise<{ exitCode: number; signal?: number }> {
    let timeout: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        exitPromise,
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(failureContext(message)), 15_000);
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  try {
    await access(bunPath);
    await access(entryPath);
    await access(powerShellPath);
    await mkdir(eventDirectory, { recursive: true });
    await writeFile(eventPath, fixtureLines(), "utf8");
    await writeFile(brokerDescriptorPath, JSON.stringify({ requestLogPath }, null, 2), "utf8");
    await writeFile(brokerScriptPath, String.raw`
param([string]$DescriptorPath)
$descriptor = Get-Content -Raw -Path $DescriptorPath | ConvertFrom-Json
$requestLogPath = $descriptor.requestLogPath
$repositoryIdentity = @{
  schemaVersion = 1
  provider = 'GitHub'
  repositoryId = '10400000000000001'
  organization = 'devpilot'
  project = ''
  repositoryName = 'operations-dashboard'
  slug = 'devpilot/operations-dashboard'
  key = 'v1:github:10400000000000001'
  verifiedAtUtc = '2026-09-03T15:00:00Z'
  verified = $true
  dispatchEligible = $true
}
$prSnapshot = @{
  schemaVersion = 1
  pullRequestId = 104
  sourceCommit = ('a' * 40)
  sourceRef = 'joerob/issue-104'
  targetRef = 'main'
  active = $true
  draft = $false
  author = 'Ada'
  title = 'ConPTY live flow'
}
$enabled = @('EnableSummaryComment', 'EnableThreadReplies')
$mandatory = @('EnableFindingComments', 'EnableApprovalVote')
$killSwitchActive = $false
$killSwitchExpiresAtUtc = $null
function Append-Log([object]$request) {
  [System.IO.File]::AppendAllText($requestLogPath, (($request | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine))
}
function Current-Provenance([bool]$killSwitchOn) {
  if ($killSwitchOn) {
    return [ordered]@{
      EnableFindingComments = 'kill-switch'
      EnableSummaryComment = 'kill-switch'
      EnableThreadReplies = 'kill-switch'
      EnableApprovalVote = 'kill-switch'
    }
  }
  return [ordered]@{
    EnableFindingComments = 'repo-worktree'
    EnableSummaryComment = 'machine'
    EnableThreadReplies = 'user'
    EnableApprovalVote = 'operational-default'
  }
}
function Current-Effect([string[]]$enabledValues, [string[]]$mandatoryValues, [bool]$killSwitchOn) {
  return @{
    capabilities = @($enabledValues)
    mandatoryDenies = @($mandatoryValues)
    provenance = Current-Provenance $killSwitchOn
  }
}
function Profile-Response([object]$request) {
  $effect = Current-Effect $enabled $mandatory $killSwitchActive
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'capability-profile'
    role = $request.role
    repositoryIdentity = $repositoryIdentity
    prSnapshot = $prSnapshot
    capabilities = $effect.capabilities
    mandatoryDenies = $effect.mandatoryDenies
    dynamicConstraints = @()
    absoluteDenies = @('EnableApprovalVote')
    allowedManualCapabilities = @('EnableFindingComments', 'EnableSummaryComment', 'EnableThreadReplies')
    delegableAvailable = @()
    provenance = $effect.provenance
    killSwitchActive = $killSwitchActive
    killSwitchExpiresAtUtc = $killSwitchExpiresAtUtc
  } | ConvertTo-Json -Compress -Depth 10
}
function Set-KillSwitch-Response([object]$request) {
  # Mirrors Invoke-SetKillSwitch's real wire shape (issue #105 PR3 completion): flips the
  # fixture's own shared $killSwitchActive/$killSwitchExpiresAtUtc state so the very next
  # profile response reflects it too, exactly like the real broker's persisted sentinel would.
  $script:killSwitchActive = [bool]$request.enabled
  $script:killSwitchExpiresAtUtc = if ($script:killSwitchActive) { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 } else { $null }
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'kill-switch-applied'
    role = $request.role
    enabled = $script:killSwitchActive
    killSwitchExpiresAtUtc = $script:killSwitchExpiresAtUtc
  } | ConvertTo-Json -Compress -Depth 10
}
function Preview-Response([object]$request) {
  $current = Current-Effect $enabled $mandatory $killSwitchActive
  if ($request.action -eq 'off') {
    $proposedEnabled = @($enabled | Where-Object { $_ -ne $request.capability })
    $proposedMandatory = @(($mandatory + $request.capability) | Select-Object -Unique)
  } else {
    $proposedEnabled = @(($enabled + $request.capability) | Select-Object -Unique)
    $proposedMandatory = @($mandatory | Where-Object { $_ -ne $request.capability })
  }
  $proposed = Current-Effect $proposedEnabled $proposedMandatory $killSwitchActive
  $changed = @(Compare-Object $current.capabilities $proposed.capabilities).Length -ne 0 -or @(Compare-Object $current.mandatoryDenies $proposed.mandatoryDenies).Length -ne 0
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'narrowing-preview'
    state = 'previewed'
    role = $request.role
    repositoryIdentity = $repositoryIdentity
    prSnapshot = $prSnapshot
    scope = $request.scope
    capability = $request.capability
    action = $request.action
    previewToken = ('preview-{0}-{1}-{2}' -f $request.scope, $request.capability, $request.action)
    storeFingerprint = ('store-' + ($(if ($killSwitchActive) { 'kill-switch' } else { 'normal' })))
    expiresAtUtc = '2026-09-03T16:00:00Z'
    killSwitchActive = $killSwitchActive
    changed = $changed
    current = $current
    proposed = $proposed
  } | ConvertTo-Json -Compress -Depth 10
}
$accepting = $true
while ($accepting -and $null -ne ($line = [Console]::In.ReadLine())) {
  $request = $line | ConvertFrom-Json
  Append-Log $request
  switch ($request.operation) {
    'get-automation-status' {
      Write-Output (@{schemaVersion=1;requestId=$request.requestId;operation='automation-status'
        automationVersion=1;available=$false;scope=$null;agents=@()
      } | ConvertTo-Json -Compress)
    }
    'profile' { Write-Output (Profile-Response $request) }
    'preview-narrowing' { Write-Output (Preview-Response $request) }
    'set-kill-switch' { Write-Output (Set-KillSwitch-Response $request) }
    'shutdown' {
      # break only exits the switch in PowerShell, not this enclosing while loop -- the
      # $accepting flag (mirroring the production broker's own shutdown handling in
      # tools/Invoke-DevPilotAgentDispatch.ps1) is what actually stops this fixture from blocking
      # on another ReadLine() forever after replying, so the dashboard's real child process exits
      # promptly instead of leaving this fixture running as an orphaned residue process.
      $accepting = $false
      Write-Output (@{
        schemaVersion = 1
        requestId = $request.requestId
        operation = 'shutdown-complete'
      } | ConvertTo-Json -Compress -Depth 10)
    }
    default { throw "unexpected operation $($request.operation)" }
  }
}
`, "utf8");

    terminal = spawn(bunPath, [
      "--conditions=browser",
      entryPath,
      "--launch-mode", "operational",
      "--state-dir", stateRoot,
      "--broker-executable", powerShellPath,
      "--broker-script", brokerScriptPath,
      "--broker-descriptor", brokerDescriptorPath,
    ], {
      name: "xterm-256color",
      cols: 130,
      rows: 36,
      cwd: dashboardRoot,
      env: environment(),
    });
    dataSubscription = terminal.onData((data) => {
      raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
      screen.write(data);
      revision++;
    });
    exitSubscription = terminal.onExit((eventExit) => {
      exited = eventExit;
      resolveExit?.(eventExit);
    });

    await waitForVisible(SIMPLE_MAIN_HINT);
    await writeAndWait("a", "FOCUS RAIL");
    await waitForVisible("DEVPILOT OPERATIONS");
    await waitForVisible("OPERATIONAL");
    await waitForVisible("TRUSTED MANUAL ENABLED");
    await writeAndWait("F", "View filter changed to History");
    await waitForVisible("operations-dashboard PR #104");
    terminal.write("F");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.write("f");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.write("104\r");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.write("x");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.write("X");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    await writeAndWait("s", "SETTINGS - EFFECTIVE CAPABILITY PROFILE");
    await writeAndWait("e", "SETTINGS - EDIT PERSISTED NARROWING");
    await writeAndWait("\x1b[C", "Scope: machine  [user]  repo-worktree  pr");
    await writeAndWait("\x1b[C", "Scope: machine  user  [repo-worktree]  pr");
    await writeAndWait("\x1b[B", "> EnableSummaryComment");
    await writeAndWait("\x1b[B", "> EnableThreadReplies");
    await writeAndWait("o", "repo-worktree / EnableThreadReplies -> off");
    await waitForVisible("First confirmation: press c to review the final apply gate; Esc cancels.");
    await writeAndWait("\x1b", "SETTINGS - EDIT PERSISTED NARROWING");
    await writeAndWait("\x1b", "SETTINGS - EFFECTIVE CAPABILITY PROFILE");

    // Kill switch first-stage cancel: k shows the full-disclosure warning; Esc backs out with no
    // set-kill-switch RPC.
    await writeAndWait("k", "WARNING: machine+user-wide emergency lever");
    await writeAndWait("\x1b", "SETTINGS - EFFECTIVE CAPABILITY PROFILE");

    // Kill switch final-stage cancel: k -> c reaches the terse final gate; Esc still backs out
    // with no RPC.
    await writeAndWait("k", "WARNING: machine+user-wide emergency lever");
    await writeAndWait("c", "FINAL CONFIRMATION: enable the kill switch machine+user-wide");
    await writeAndWait("\x1b", "SETTINGS - EFFECTIVE CAPABILITY PROFILE");

    // Enable: k -> c -> y actually toggles it on, and Settings displays the TTL expiry.
    await writeAndWait("k", "WARNING: machine+user-wide emergency lever");
    await writeAndWait("c", "FINAL CONFIRMATION: enable the kill switch machine+user-wide");
    await writeAndWait("y", "Ignore local narrowing overrides: ON (emergency lever, not a security lockdown)");
    await waitForVisible("ON (emergency lever, not a security lockdown) (expires in");

    // Disable: k -> c -> y turns it back off.
    await writeAndWait("k", "Disable 'Ignore local narrowing overrides'? Persisted narrowing becomes active again for next launches.");
    await writeAndWait("c", "FINAL CONFIRMATION: disable 'Ignore local narrowing overrides'? Persisted narrowing becomes active again.");
    await writeAndWait("y", "Ignore local narrowing overrides is now OFF: persisted narrowing applies again.");

    await writeAndWait("\x1b", "Effective profile settings closed");
    terminal.write("q");
    const result = await waitForExit("dashboard hung after quitting settings editor");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);

    const parsedRequests = await readInteractionRequests(requestLogPath);
    assert.deepEqual(parsedRequests.map((request) => request.operation), [
      "profile", "preview-narrowing", "set-kill-switch", "profile", "set-kill-switch", "profile", "shutdown",
    ]);
    assert.equal(parsedRequests[0]?.repositoryKey, "v1:github:10400000000000001");
    assert.equal(parsedRequests[1]?.scope, "repo-worktree");
    assert.equal(parsedRequests[1]?.capability, "EnableThreadReplies");
    assert.equal(parsedRequests[1]?.action, "off");
    assert.ok(!parsedRequests.some((request) => request.operation === "apply-narrowing"));
    const killSwitchRequests = parsedRequests.filter((request) => request.operation === "set-kill-switch");
    assert.equal(killSwitchRequests.length, 2);
    assert.equal(killSwitchRequests[0]?.enabled, true);
    assert.equal(killSwitchRequests[1]?.enabled, false);
  } finally {
    try {
      if (terminal && !exited) {
        terminal.kill();
        await waitForExit("dashboard did not terminate after cleanup kill");
      }
      if (terminal) {
        assert.ok(exited, "node-pty must report child termination before cleanup completes");
        disposeConptyOutputWorker(terminal);
      }
      assert.doesNotMatch(
        stripVTControlCharacters(raw),
        /AttachConsole failed|conpty_console_list_agent/i,
        failureContext("node-pty helper failure was written to the terminal").message,
      );
    } finally {
      dataSubscription?.dispose();
      exitSubscription?.dispose();
      await rm(stateRoot, { recursive: true, force: true });
    }
  }
});

test("built dashboard exercises reviewer widening through real ConPTY and cancels dispatch cleanly", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 120_000,
}, async () => {
  const dashboardRoot = resolve(".");
  const stateRoot = await mkdtemp(join(tmpdir(), "devpilot-dashboard-widening-pty-"));
  assert.ok(isAbsolute(stateRoot));
  assert.notEqual(resolve(stateRoot), dashboardRoot);

  const eventDirectory = join(stateRoot, "logs", "events", "reviewer");
  const eventPath = join(eventDirectory, "fixture.jsonl");
  const requestLogPath = join(stateRoot, "broker-requests.jsonl");
  const dispatchEventLogPath = join(stateRoot, "broker-child-events.jsonl");
  const brokerScriptPath = join(stateRoot, "fake-broker.ps1");
  const brokerDescriptorPath = join(stateRoot, "broker-descriptor.json");
  const bunPath = resolve(dashboardRoot, "node_modules", "bun", "bin", "bun.exe");
  const entryPath = resolve(dashboardRoot, "dist", "src", "index.js");
  const powerShellPath = resolvePowerShellPath();
  let terminal: IPty | undefined;
  let dataSubscription: IDisposable | undefined;
  let exitSubscription: IDisposable | undefined;
  let revision = 0;
  let raw = "";
  const screen = new TerminalScreen();
  let exited: { exitCode: number; signal?: number } | undefined;
  let resolveExit: ((exit: { exitCode: number; signal?: number }) => void) | undefined;
  const exitPromise = new Promise<{ exitCode: number; signal?: number }>((resolvePromise) => {
    resolveExit = resolvePromise;
  });

  function visibleOutput(): string {
    return screen.text();
  }

  function failureContext(message: string): Error {
    return new Error(`${message}\n--- current terminal screen ---\n${visibleOutput()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`);
  }

  async function waitForVisible(expected: string, start = 0): Promise<void> {
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline) {
      if (revision >= start && visibleOutput().includes(expected)) return;
      if (exited) throw failureContext(`dashboard exited before rendering ${JSON.stringify(expected)}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
    throw failureContext(`timed out waiting for ${JSON.stringify(expected)}`);
  }

  async function writeAndWait(bytes: string, expected: string): Promise<void> {
    assert.ok(terminal, "terminal must be running");
    const start = revision + 1;
    terminal.write(bytes);
    await waitForVisible(expected, start);
  }

  async function waitForExit(message: string): Promise<{ exitCode: number; signal?: number }> {
    let timeout: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        exitPromise,
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(failureContext(message)), 15_000);
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  try {
    await access(bunPath);
    await access(entryPath);
    await access(powerShellPath);
    await mkdir(eventDirectory, { recursive: true });
    await writeFile(eventPath, "", "utf8");
    await writeFile(dispatchEventLogPath, "", "utf8");
    await writeFile(
      brokerDescriptorPath,
      JSON.stringify({ requestLogPath, dispatchEventLogPath }, null, 2),
      "utf8",
    );
    await writeFile(brokerScriptPath, await readFile(reviewerWideningBrokerScript(), "utf8"), "utf8");

    terminal = spawn(bunPath, [
      "--conditions=browser",
      entryPath,
      "--state-dir", stateRoot,
      "--broker-executable", powerShellPath,
      "--broker-script", brokerScriptPath,
      "--broker-descriptor", brokerDescriptorPath,
    ], {
      name: "xterm-256color",
      cols: 130,
      rows: 36,
      cwd: dashboardRoot,
      env: environment(),
    });
    dataSubscription = terminal.onData((data) => {
      raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
      screen.write(data);
      revision++;
    });
    exitSubscription = terminal.onExit((eventExit) => {
      exited = eventExit;
      resolveExit?.(eventExit);
    });

    await waitForVisible(SIMPLE_MAIN_HINT);
    await writeAndWait("a", "FOCUS RAIL");
    await waitForVisible("DEVPILOT OPERATIONS");
    await waitForVisible("TRUSTED MANUAL ENABLED");
    await writeAndWait("m", "START AGENT BY PR ID");
    await writeAndWait("\x1b", "Start Agent by PR ID");
    await writeAndWait("m", "PR ID: (blank)");
    await writeAndWait("1.2\r", "PR ID must be in 1..2147483647.");
    await writeAndWait("\x15104\r", "Press w to request EnableApprovalVote widening (draft-bound, single-use).");
    await writeAndWait("w", "Widening preview: EnableApprovalVote");
    await waitForVisible("Paired requirement: EnableFindingComments must already be active (confirmed active).");
    await waitForVisible("Would add: EnableApprovalVote");
    await waitForVisible("Would remove from denies: EnableApprovalVote");
    await writeAndWait("c", "widening blast radius: EnableApprovalVote");
    await waitForVisible("Single-use grant; expires");
    await waitForVisible("FINAL WIDENING CONFIRMATION: press y to mint this grant; Esc cancels.");
    await writeAndWait("y", "Widening grant minted and active for this draft.");

    const preDispatchOperations = await readRequestOperations(requestLogPath);
    assert.deepEqual(preDispatchOperations, [
      "profile-current",
      "describe",
      "describe-widening",
      "confirm-widening-preview",
      "confirm-widening-mint",
    ]);
    const preDispatchRequests = await readInteractionRequests(requestLogPath);
    assert.equal(preDispatchRequests[0]?.repositoryKey, undefined);
    assert.equal(preDispatchRequests[0]?.pullRequestId, 104);
    assert.equal(preDispatchRequests[1]?.repositoryKey, "v1:github:10400000000000001");
    assert.equal(preDispatchRequests[2]?.capability, "EnableApprovalVote");
    assert.equal(preDispatchRequests[3]?.challenge, "a".repeat(48));
    assert.equal(preDispatchRequests[4]?.challenge, "b".repeat(48));

    await writeAndWait("\r", "STARTED / RUNNING");
    await waitForVisible("Waiting for first progress");
    await waitForVisible("Child PID 4242");
    await writeAndWait("c", "CANCELLED");
    await writeAndWait("\r", "INSTANCES");

    terminal.write("q");
    const result = await waitForExit("dashboard hung after quitting widened flow");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);

    const parsedRequests = await readRequestOperations(requestLogPath);
    assert.deepEqual(parsedRequests, [
      "profile-current",
      "describe",
      "describe-widening",
      "confirm-widening-preview",
      "confirm-widening-mint",
      "dispatch",
      "cancel",
      "shutdown",
    ]);
  } finally {
    try {
      if (terminal && !exited) {
        terminal.kill();
        await waitForExit("dashboard did not terminate after cleanup kill");
      }
      if (terminal) {
        assert.ok(exited, "node-pty must report child termination before cleanup completes");
        disposeConptyOutputWorker(terminal);
      }
      assert.doesNotMatch(
        stripVTControlCharacters(raw),
        /AttachConsole failed|conpty_console_list_agent/i,
        failureContext("node-pty helper failure was written to the terminal").message,
      );
    } finally {
      dataSubscription?.dispose();
      exitSubscription?.dispose();
      await rm(stateRoot, { recursive: true, force: true });
    }
  }
});

test("built dashboard cancels reviewer widening with Esc and leaves no broker residue", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 90_000,
}, async () => {
  const dashboardRoot = resolve(".");
  const stateRoot = await mkdtemp(join(tmpdir(), "devpilot-dashboard-widening-cancel-"));
  assert.ok(isAbsolute(stateRoot));
  assert.notEqual(resolve(stateRoot), dashboardRoot);

  const eventDirectory = join(stateRoot, "logs", "events", "reviewer");
  const eventPath = join(eventDirectory, "fixture.jsonl");
  const requestLogPath = join(stateRoot, "broker-requests.jsonl");
  const dispatchEventLogPath = join(stateRoot, "broker-child-events.jsonl");
  const brokerScriptPath = join(stateRoot, "fake-broker.ps1");
  const brokerDescriptorPath = join(stateRoot, "broker-descriptor.json");
  const bunPath = resolve(dashboardRoot, "node_modules", "bun", "bin", "bun.exe");
  const entryPath = resolve(dashboardRoot, "dist", "src", "index.js");
  const powerShellPath = resolvePowerShellPath();
  let terminal: IPty | undefined;
  let dataSubscription: IDisposable | undefined;
  let exitSubscription: IDisposable | undefined;
  let revision = 0;
  let raw = "";
  const screen = new TerminalScreen();
  let exited: { exitCode: number; signal?: number } | undefined;
  let resolveExit: ((exit: { exitCode: number; signal?: number }) => void) | undefined;
  const exitPromise = new Promise<{ exitCode: number; signal?: number }>((resolvePromise) => {
    resolveExit = resolvePromise;
  });

  function visibleOutput(): string {
    return screen.text();
  }

  function failureContext(message: string): Error {
    return new Error(`${message}\n--- current terminal screen ---\n${visibleOutput()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`);
  }

  async function waitForVisible(expected: string, start = 0): Promise<void> {
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline) {
      if (revision >= start && visibleOutput().includes(expected)) return;
      if (exited) throw failureContext(`dashboard exited before rendering ${JSON.stringify(expected)}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
    throw failureContext(`timed out waiting for ${JSON.stringify(expected)}`);
  }

  async function writeAndWait(bytes: string, expected: string): Promise<void> {
    assert.ok(terminal, "terminal must be running");
    const start = revision + 1;
    terminal.write(bytes);
    await waitForVisible(expected, start);
  }

  async function waitForExit(message: string): Promise<{ exitCode: number; signal?: number }> {
    let timeout: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        exitPromise,
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(failureContext(message)), 15_000);
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  try {
    await access(bunPath);
    await access(entryPath);
    await access(powerShellPath);
    await mkdir(eventDirectory, { recursive: true });
    await writeFile(eventPath, "", "utf8");
    await writeFile(dispatchEventLogPath, "", "utf8");
    await writeFile(
      brokerDescriptorPath,
      JSON.stringify({ requestLogPath, dispatchEventLogPath }, null, 2),
      "utf8",
    );
    await writeFile(brokerScriptPath, await readFile(reviewerWideningBrokerScript(), "utf8"), "utf8");

    terminal = spawn(bunPath, [
      "--conditions=browser",
      entryPath,
      "--state-dir", stateRoot,
      "--broker-executable", powerShellPath,
      "--broker-script", brokerScriptPath,
      "--broker-descriptor", brokerDescriptorPath,
    ], {
      name: "xterm-256color",
      cols: 130,
      rows: 36,
      cwd: dashboardRoot,
      env: environment(),
    });
    dataSubscription = terminal.onData((data) => {
      raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
      screen.write(data);
      revision++;
    });
    exitSubscription = terminal.onExit((eventExit) => {
      exited = eventExit;
      resolveExit?.(eventExit);
    });

    await waitForVisible(SIMPLE_MAIN_HINT);
    await writeAndWait("a", "FOCUS RAIL");
    await waitForVisible("DEVPILOT OPERATIONS");
    await waitForVisible("TRUSTED MANUAL ENABLED");
    await writeAndWait("m", "START AGENT BY PR ID");
    await writeAndWait("104\r", "Press w to request EnableApprovalVote widening (draft-bound, single-use).");
    await writeAndWait("w", "Widening preview: EnableApprovalVote");
    await waitForVisible("Paired requirement: EnableFindingComments must already be active (confirmed active).");
    await writeAndWait("c", "widening blast radius: EnableApprovalVote");
    await waitForVisible("FINAL WIDENING CONFIRMATION: press y to mint this grant; Esc cancels.");
    await writeAndWait("\x1b", "Widening cancelled; capability profile refreshed to the unwidened baseline.");
    await waitForVisible("Press w to request EnableApprovalVote widening (draft-bound, single-use).");
    await writeAndWait("\x1b", "INSTANCES");

    terminal.write("q");
    const result = await waitForExit("dashboard hung after quitting Esc cancellation flow");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);

    const parsedRequests = await readRequestOperations(requestLogPath);
    assert.deepEqual(parsedRequests, [
      "profile-current",
      "describe",
      "describe-widening",
      "confirm-widening-preview",
      "cancel-widening",
      "shutdown",
    ]);
    const cancelRequests = await readInteractionRequests(requestLogPath);
    assert.equal(cancelRequests[4]?.generation, 2);
  } finally {
    try {
      if (terminal && !exited) {
        terminal.kill();
        await waitForExit("dashboard did not terminate after cleanup kill");
      }
      if (terminal) {
        assert.ok(exited, "node-pty must report child termination before cleanup completes");
        disposeConptyOutputWorker(terminal);
      }
      assert.doesNotMatch(
        stripVTControlCharacters(raw),
        /AttachConsole failed|conpty_console_list_agent/i,
        failureContext("node-pty helper failure was written to the terminal").message,
      );
    } finally {
      dataSubscription?.dispose();
      exitSubscription?.dispose();
      await rm(stateRoot, { recursive: true, force: true });
    }
  }
});

test("real ConPTY Enter flow shows starting, late progress, completion and cancellation across both roles and widths", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 120_000,
}, async () => {
  for (const width of [70, 100, 140]) {
    const role = width === 100 ? "review-handler" : "reviewer";
    const previewOnly = width === 140;
    const root = await mkdtemp(join(tmpdir(), "devpilot-dashboard-enter-"));
    const requestLogPath = join(root, "requests.jsonl");
    const eventLogPath = join(root, "late.jsonl");
    const descriptorPath = join(root, "descriptor.json");
    const dispatchId = randomUUID();
    let terminal: IPty | undefined;
    let revision = 0;
    let raw = "";
    const screen = new TerminalScreen();
    screen.resize(width, 36);
    let exited: PtyExit | undefined;
    let dataSubscription: IDisposable | undefined;
    let exitSubscription: IDisposable | undefined;
    const visible = () => screen.text();
    async function waitFor(expected: string, start = 0): Promise<void> {
      const until = Date.now() + 8_000;
      while (revision < start || !visible().includes(expected)) {
        if (exited || Date.now() > until) throw new Error(`Expected ${expected} at ${width} columns\n${visible()}\nRAW tail: ${JSON.stringify(raw.slice(-2000))}`);
        await new Promise((resolveWait) => setTimeout(resolveWait, 25));
      }
    }
    async function send(bytes: string, expected: string): Promise<void> {
      const start = revision + 1;
      terminal!.write(bytes);
      await waitFor(expected, start);
    }
    try {
      await writeFile(descriptorPath, JSON.stringify({
        requestLogPath, dispatchEventLogPath: eventLogPath, simpleFlow: true, role,
        dispatchId, previewOnly, complete: role === "review-handler",
      }));
      terminal = spawn(resolve("node_modules", "bun", "bin", "bun.exe"), [
        "--conditions=browser", resolve("dist", "src", "index.js"),
        "--state-dir", root, "--launch-mode", previewOnly ? "preview" : "operational",
        "--broker-executable", resolvePowerShellPath(), "--broker-script", reviewerWideningBrokerScript(),
        "--broker-descriptor", descriptorPath,
      ], { name: "xterm-256color", cols: width, rows: 36, cwd: resolve("."), env: environment() });
      dataSubscription = terminal.onData((data) => {
        raw = (raw + data).slice(-MAX_CAPTURE_CHARS);
        screen.write(data);
        revision++;
      });
      exitSubscription = terminal.onExit((exit) => { exited = exit; });
      await waitFor(SIMPLE_MAIN_HINT);
      await send("a", "INSTANCES");
      await waitFor("DEVPILOT OPERATIONS");
      await send("m", "PR ID: (blank)");
      if (role === "review-handler") await send("\t", "Agent: Review Handler");
      await send("104\r\r", "NOT STARTED / READY TO START");
      assert.deepEqual(await readRequestOperations(requestLogPath), ["profile-current", "describe"]);
      if (width === 70) {
        await send("p", "Optional instructions");
        terminal.write("first\x1b[13;2u\x1b[200~second\r\nq d y c\x1b[201~");
        await new Promise((resolveWait) => setTimeout(resolveWait, 150));
        await send("\r\r", "NOT STARTED / READY TO START");
        assert.deepEqual(await readRequestOperations(requestLogPath), ["profile-current", "describe"]);
      }
      if (previewOnly) await waitFor("No PR comments or code pushes");
      else await waitFor(role === "reviewer" ? "finding comments" : "code pushes");
      // Ignored key repeats need not emit a frame; verify the unchanged screen and request log.
      terminal.write("\x1b[13;1:2u");
      await new Promise((resolveWait) => setTimeout(resolveWait, 150));
      await waitFor("Enter: START");
      assert.deepEqual(await readRequestOperations(requestLogPath), ["profile-current", "describe"]);
      await send("\r\r", "STARTING...");
      await waitFor("STARTED / RUNNING");
      await waitFor("Waiting for first progress");
      await waitFor("Child PID 4242");
      terminal.write("\r\r");
      assert.equal((await readRequestOperations(requestLogPath)).filter((operation) => operation === "dispatch").length, 1);
      assert.doesNotMatch(visible(), /SOURCE WARNING/);
      const manualEvent = (sequence: number, type: string, data: Record<string, unknown>, manual = true): string => {
        const value = JSON.parse(event(role, manual ? "manual-enter" : "automatic-same-pr", sequence, type, data));
        return JSON.stringify({
          ...value, processId: manual ? 4242 : 5555, timestamp: new Date().toISOString(),
          dispatch: manual ? { schemaVersion: 1, dispatchId, ownership: "tui", forceAnalysis: true } : null,
        }) + "\n";
      };
      await writeFile(eventLogPath, manualEvent(1, "work.completed", { result: "failed" }, false));
      await appendFile(eventLogPath, manualEvent(1, "agent.started", {}));
      await appendFile(eventLogPath, manualEvent(2, "phase.changed", { phase: "Inspecting manual changes" }));
      await waitFor("Phase: Inspecting manual changes");
      if (role === "review-handler") {
        await appendFile(eventLogPath, manualEvent(3, "work.completed", { result: "handled", summary: "Manual handler finished" }));
        await waitFor("FINISHED");
        await waitFor("Manual handler finished");
      } else {
        await send("cc\r", "CANCELLING...");
        await waitFor("CANCELLED");
      }
      await send("\r", "INSTANCES");
      terminal.write("q");
      const until = Date.now() + 15_000;
      while (!exited && Date.now() < until) await new Promise((resolveWait) => setTimeout(resolveWait, 25));
      assert.equal(exited?.exitCode, 0, "fixture dashboard must quit cleanly");
      const requests = (await readFile(requestLogPath, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
      const dispatched = requests.filter((request) => request.operation === "dispatch");
      assert.equal(dispatched.length, 1);
      assert.equal(dispatched[0].role, role);
      assert.equal(dispatched[0].operatorPrompt, width === 70 ? "first\nsecond\nq d y c" : "");
      assert.equal(requests.some((request) => /widening/.test(request.operation)), false);
    } finally {
      if (terminal && !exited) {
        terminal.kill();
        const until = Date.now() + EXIT_TIMEOUT_MS;
        while (!exited && Date.now() < until) await new Promise((resolveWait) => setTimeout(resolveWait, 25));
      }
      if (terminal) disposeConptyOutputWorker(terminal);
      dataSubscription?.dispose();
      exitSubscription?.dispose();
      await rm(root, { recursive: true, force: true });
    }
  }
});
