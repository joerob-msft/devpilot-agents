import assert from "node:assert/strict";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import test from "node:test";
import { stripVTControlCharacters } from "node:util";
import { execFileSync } from "node:child_process";
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
    terminal.write("F");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("f");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    await writeAndWait("\t", "HISTORY | REVIEWER");
    await writeAndWait("\t", "HISTORY | REVIEW-HANDLER");
    await writeAndWait("\t", "HISTORY | ALL");
    await writeAndWait("\x1b[Z", "HISTORY | REVIEW-HANDLER");
    await writeAndWait("\x1b[Z", "HISTORY | REVIEWER");
    await writeAndWait("m", "Observe-only launch: trusted manual broker is unavailable");

    await writeAndWait("i", "Inspector closed");
    await writeAndWait("i", "Inspector opened and focused");
    await writeAndWait("e", "RAW EVENTS - ALL");
    const scrollStart = visibleOutput().length;
    terminal.write("\x1b[A".repeat(12));
    await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    await waitForVisible("scroll marker 01", scrollStart);
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
    terminal.write("104\r");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("x");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("X");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);

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
  let terminalColumns = 130;
  let terminalRows = 36;
  let capture = "";
  let exited: { exitCode: number; signal?: number } | undefined;
  let resolveExit: ((exit: { exitCode: number; signal?: number }) => void) | undefined;
  const exitPromise = new Promise<{ exitCode: number; signal?: number }>((resolvePromise) => {
    resolveExit = resolvePromise;
  });

  function visibleOutput(): string {
    return stripVTControlCharacters(capture);
  }

  function failureContext(message: string): Error {
    return new Error(`${message}\n--- captured terminal output ---\n${visibleOutput().slice(-8_000)}`);
  }

  async function waitForVisible(expected: string, start = 0): Promise<void> {
    const deadline = Date.now() + 8_000;
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
    'profile' { Write-Output (Profile-Response $request) }
    'preview-narrowing' { Write-Output (Preview-Response $request) }
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
      capture = (capture + data).slice(-1_000_000);
    });
    exitSubscription = terminal.onExit((eventExit) => {
      exited = eventExit;
      resolveExit?.(eventExit);
    });

    await waitForVisible("DEVPILOT OPERATIONS");
    await waitForVisible("TRUSTED MANUAL ENABLED");
    await writeAndWait("f", "View filter changed to History");
    await waitForVisible("operations-dashboard PR #104");
    terminal.write("F");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("f");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("104\r");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("x");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
    terminal.write("X");
    await new Promise((resolveWait) => setTimeout(resolveWait, 75));
    terminal.resize(terminalColumns, terminalRows - 1);
    terminal.resize(terminalColumns, terminalRows);
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
    await writeAndWait("\x1b", "Effective profile settings closed");
    terminal.write("q");
    const result = await waitForExit("dashboard hung after quitting settings editor");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);

    const requests = readFile(requestLogPath, "utf8")
      .then((content) =>
        content.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>));
    const parsedRequests = await requests;
    assert.deepEqual(parsedRequests.map((request) => request.operation), ["profile", "preview-narrowing", "shutdown"]);
    assert.equal(parsedRequests[0]?.repositoryKey, "v1:github:10400000000000001");
    assert.equal(parsedRequests[1]?.scope, "repo-worktree");
    assert.equal(parsedRequests[1]?.capability, "EnableThreadReplies");
    assert.equal(parsedRequests[1]?.action, "off");
    assert.ok(!parsedRequests.some((request) => request.operation === "apply-narrowing"));
    assert.ok(!parsedRequests.some((request) => request.operation === "set-kill-switch"));
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
