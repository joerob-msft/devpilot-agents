import assert from "node:assert/strict";
import { access, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import test from "node:test";
import { stripVTControlCharacters } from "node:util";
import { spawn, type IDisposable, type IPty } from "node-pty";

const WAIT_TIMEOUT_MS = 8_000;
const EXIT_TIMEOUT_MS = 5_000;
const MAX_CAPTURE_CHARS = 1_000_000;

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
    event("reviewer", "pty-reviewer", 4, "work.completed", {
      result: "reviewed",
      summary: "Renderer and protocol verification complete",
    }),
    event("reviewer", "pty-reviewer", 5, "agent.stopped", {}),
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

function environment(): Record<string, string> {
  return Object.fromEntries(
    Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  );
}

test("built dashboard accepts real ConPTY input and exits cleanly", {
  skip: process.platform === "win32" ? false : "ConPTY integration is Windows-only",
  timeout: 60_000,
}, async () => {
  const dashboardRoot = resolve(".");
  const stateRoot = await mkdtemp(join(tmpdir(), "devpilot-dashboard-pty-"));
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
  let capture = "";
  let exited: PtyExit | undefined;
  let resolveExit: ((exit: PtyExit) => void) | undefined;
  const exitPromise = new Promise<PtyExit>((resolvePromise) => {
    resolveExit = resolvePromise;
  });

  function visibleOutput(): string {
    return stripVTControlCharacters(capture);
  }

  function failureContext(message: string): Error {
    return new Error(`${message}\n--- captured terminal output ---\n${visibleOutput().slice(-8_000)}`);
  }

  async function waitForVisible(expected: string, start = 0): Promise<void> {
    const deadline = Date.now() + WAIT_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (visibleOutput().slice(start).includes(expected)) return;
      if (exited) throw failureContext(`dashboard exited before rendering ${JSON.stringify(expected)}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
    throw failureContext(`timed out waiting for ${JSON.stringify(expected)}`);
  }

  async function writeAndWait(bytes: string, expected: string): Promise<void> {
    assert.ok(terminal, "terminal must be running");
    const start = visibleOutput().length;
    terminal.write(bytes);
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
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

    terminal = spawn(bunPath, ["--conditions=browser", entryPath, "--state-dir", stateRoot], {
      name: "xterm-256color",
      cols: 130,
      rows: 36,
      cwd: dashboardRoot,
      env: environment(),
    });
    dataSubscription = terminal.onData((data) => {
      capture = (capture + data).slice(-MAX_CAPTURE_CHARS);
    });
    exitSubscription = terminal.onExit((eventExit) => {
      exited = eventExit;
      resolveExit?.(eventExit);
    });

    await waitForVisible("DEVPILOT OPERATIONS");
    await waitForVisible("OBSERVE ONLY");
    await waitForVisible("ConPTY live flow");

    await writeAndWait("?", "HELP - OBSERVE MODE");
    await waitForVisible("Left / Right");
    await writeAndWait("\x1b", "Help closed");

    await writeAndWait("f", "View filter changed to History");
    await waitForVisible("operations-dashboard PR #104");
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
    await writeAndWait("\x1b[C", "RAW EVENTS - WARNINGS");
    await writeAndWait("\x1b", "Events overlay closed");

    await writeAndWait("\x10", "CONTEXT COMMANDS - VIEW ONLY");
    await writeAndWait("\x1b", "Command palette closed");

    await writeAndWait("/missing\r", "PR HISTORY 0");
    assert.match(visibleOutput(), /filter: missing/);
    await writeAndWait("/\x7f\x7f\x7f\x7f\x7f\x7f\x7f\r", "> operations-dashboard PR #104");
    await writeAndWait("/cancelled", "filter: cancelled");
    terminal.write("\x1b");
    await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    await writeAndWait("104\r", "Jumped to operations-dashboard PR #104");

    await writeAndWait("x", "PR history row hidden for this dashboard process");
    await writeAndWait("X", "> operations-dashboard PR #104");

    assert.ok(terminal);
    let resizeStart = visibleOutput().length;
    terminalColumns = 70;
    terminalRows = 24;
    terminal.resize(terminalColumns, terminalRows);
    await waitForVisible("HISTORY | REVIEWER | FOCUS RAIL", resizeStart);
    resizeStart = visibleOutput().length;
    terminalColumns = 130;
    terminalRows = 36;
    terminal.resize(terminalColumns, terminalRows);
    await waitForVisible("HISTORY | REVIEWER | WIDE | FOCUS RAIL", resizeStart);

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
        visibleOutput(),
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
