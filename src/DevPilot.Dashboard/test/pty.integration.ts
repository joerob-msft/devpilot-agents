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

function reviewerWideningBrokerScript(): string {
  return resolve("test\\fixtures\\reviewer-widening-broker.ps1");
}
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

async function readRequestOperations(path: string): Promise<string[]> {
  const content = await readFile(path, "utf8");
  return content
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => (JSON.parse(line) as Record<string, unknown>).operation as string);
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
    await writeAndWait("y", "Ignore local narrowing overrides is now ON: persisted narrowing is ignored until the next launch.");
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

    const requests = readFile(requestLogPath, "utf8")
      .then((content) =>
        content.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>));
    const parsedRequests = await requests;
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
    await writeAndWait("m", "Ctrl+D describe");
    await writeAndWait("\x04", "Press w to request EnableApprovalVote widening (draft-bound, single-use).");
    await writeAndWait("w", "Widening preview: EnableApprovalVote");
    await waitForVisible("Paired requirement: EnableFindingComments must already be active (confirmed active).");
    await waitForVisible("Would add: EnableApprovalVote");
    await waitForVisible("Would remove from denies: EnableApprovalVote");
    await writeAndWait("c", "Final widening blast radius: EnableApprovalVote");
    await waitForVisible("Single-use grant; expires");
    await waitForVisible("FINAL WIDENING CONFIRMATION: press y to mint this grant; Esc cancels.");
    await writeAndWait("y", "Widening grant minted and active for this draft; continue with d then y to dispatch, or Esc to close and relinquish it.");

    const preDispatchOperations = await readRequestOperations(requestLogPath);
    assert.deepEqual(preDispatchOperations, [
      "describe",
      "describe-widening",
      "confirm-widening-preview",
      "confirm-widening-mint",
    ]);
    const preDispatchRequests = (await readFile(requestLogPath, "utf8"))
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    assert.equal(preDispatchRequests[0]?.repositoryKey, "v1:github:10400000000000001");
    assert.equal(preDispatchRequests[1]?.capability, "EnableApprovalVote");
    assert.equal(preDispatchRequests[2]?.challenge, "a".repeat(48));
    assert.equal(preDispatchRequests[3]?.challenge, "b".repeat(48));

    await writeAndWait("d", "FINAL CONFIRMATION: press y to dispatch this exact snapshot; Esc cancels.");
    await writeAndWait("y", "Accepted dispatch");
    await waitForVisible("Dispatch accepted; waiting for correlated v3 child events.");
    await waitForVisible("Correlated v3 events:");
    await writeAndWait("c", "Cancellation completed: cooperatively.");
    await writeAndWait("\r", "PR HISTORY");

    terminal.write("q");
    const result = await waitForExit("dashboard hung after quitting widened flow");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);

    const parsedRequests = await readRequestOperations(requestLogPath);
    assert.deepEqual(parsedRequests, [
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
    await writeAndWait("m", "Ctrl+D describe");
    await writeAndWait("\x04", "Press w to request EnableApprovalVote widening (draft-bound, single-use).");
    await writeAndWait("w", "Widening preview: EnableApprovalVote");
    await waitForVisible("Paired requirement: EnableFindingComments must already be active (confirmed active).");
    await writeAndWait("c", "Final widening blast radius: EnableApprovalVote");
    await waitForVisible("FINAL WIDENING CONFIRMATION: press y to mint this grant; Esc cancels.");
    await writeAndWait("\x1b", "Widening cancelled; capability profile refreshed to the unwidened baseline.");
    await waitForVisible("Press w to request EnableApprovalVote widening (draft-bound, single-use).");
    await writeAndWait("\x1b", "PR HISTORY");

    terminal.write("q");
    const result = await waitForExit("dashboard hung after quitting Esc cancellation flow");
    assert.equal(result.exitCode, 0, failureContext("dashboard did not exit cleanly").message);
    assert.equal(result.signal ?? 0, 0, failureContext("dashboard exited due to a signal").message);

    const parsedRequests = await readRequestOperations(requestLogPath);
    assert.deepEqual(parsedRequests, [
      "describe",
      "describe-widening",
      "confirm-widening-preview",
      "cancel-widening",
      "shutdown",
    ]);
    const cancelRequests = (await readFile(requestLogPath, "utf8"))
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    assert.equal(cancelRequests[3]?.generation, 2);
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
