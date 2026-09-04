import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { DispatchClient, DISPATCH_PROTOCOL_MAX_BYTES } from "../src/dispatch.js";

// PowerShell (pwsh) ships on every GitHub-hosted runner image (Windows, Linux,
// macOS), so the fixture below can exercise the real broker process on every
// platform instead of only on Windows. Resolving it via the platform lookup
// tool keeps the fixture honest (an absolute, trusted path) without hardcoding
// a location that only exists on one OS.
function resolvePwshPath(): string {
  const lookupTool = process.platform === "win32" ? "where.exe" : "which";
  const output = execFileSync(lookupTool, ["pwsh"], { encoding: "utf8" });
  const resolved = output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0);
  if (!resolved) {
    throw new Error("pwsh executable not found on PATH");
  }
  return resolved;
}

test("protocol framing limit includes the newline", () => {
  const frame = `${JSON.stringify({ schemaVersion: 1, operation: "shutdown" })}\n`;
  assert.ok(Buffer.byteLength(frame, "utf8") <= DISPATCH_PROTOCOL_MAX_BYTES);
});

test("client rejects non-absolute executable and broker paths", () => {
  assert.throws(
    () => new DispatchClient({ executablePath: "pwsh", scriptPath: "broker.ps1", descriptorPath: "descriptor.json" }),
    /absolute trusted path/,
  );
});

test("production client correlates describe, dispatch, cancel, and shutdown under pwsh", async () => {
  const root = join(process.cwd(), `.dashboard-dispatch-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const script = join(root, "fake-broker.ps1");
  const descriptor = join(root, "descriptor.json");
  const pwsh = resolvePwshPath();
  await writeFile(descriptor, "{}", "utf8");
  await writeFile(script, String.raw`
param([string]$DescriptorPath)
$cancelCount = 0
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $r = $line | ConvertFrom-Json
  if ($r.operation -eq 'describe') {
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@('EnableSummaryComment');mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@('EnableFindingComments','EnableSummaryComment','EnableThreadReplies');delegableAvailable=@();provenance=@{EnableFindingComments='operational-default';EnableSummaryComment='operational-default';EnableThreadReplies='operational-default';EnableApprovalVote='operational-default'}} | ConvertTo-Json -Compress -Depth 10
  } elseif ($r.operation -eq 'dispatch') {
    @{schemaVersion=1;requestId=$r.requestId;operation='accepted';dispatchId='22222222-2222-4222-8222-222222222222';repositoryIdentity=@{};pullRequestId=104;role='reviewer';capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);childProcessId=42;eventLogPath=(Join-Path $PSScriptRoot 'event.jsonl')} | ConvertTo-Json -Compress -Depth 10
  } elseif ($r.operation -eq 'cancel') {
    $cancelCount++
    if ($cancelCount -eq 1) {
      @{schemaVersion=1;requestId=$r.requestId;operation='cancelled';dispatchId=$r.dispatchId;result='cancelled-forced';handleReleaseObserved=$true} | ConvertTo-Json -Compress
    } else {
      @{schemaVersion=1;requestId=$r.requestId;operation='completed';dispatchId=$r.dispatchId;exitCode=0;handleReleaseObserved=$true} | ConvertTo-Json -Compress
    }
  } elseif ($r.operation -eq 'shutdown') {
    @{schemaVersion=1;requestId=$r.requestId;operation='shutdown-complete'} | ConvertTo-Json -Compress
    break
  }
}
`, "utf8");
  const paths: string[] = [];
  const terminals: string[] = [];
  const failures: string[] = [];
  const client = new DispatchClient(
    { executablePath: pwsh, scriptPath: script, descriptorPath: descriptor },
    {
      onAcceptedEventPath: (path) => paths.push(path),
      onTerminal: (terminal) => terminals.push(terminal.operation),
      onBrokerFailure: (failure) => failures.push(failure),
    },
  );
  try {
    const summary = await client.describe("v1:github:9007199254740993", 104, "reviewer");
    assert.equal(summary.role, "reviewer");
    assert.ok(summary.mandatoryDenies.includes("EnableApprovalVote"));
    assert.deepEqual(summary.absoluteDenies, []);
    assert.deepEqual(summary.delegableAvailable, []);
    assert.deepEqual(
      [...summary.allowedManualCapabilities].sort(),
      ["EnableFindingComments", "EnableSummaryComment", "EnableThreadReplies"],
    );
    assert.equal(summary.provenance.EnableApprovalVote, "operational-default");
    assert.equal(summary.provenance.EnableSummaryComment, "operational-default");
    const accepted = await client.dispatch(summary, "prompt remains protocol data only");
    assert.equal(accepted.dispatchId, "22222222-2222-4222-8222-222222222222");
    assert.equal(paths.length, 1);
    const cancelled = await client.cancel(accepted.dispatchId);
    assert.equal(cancelled.result, "cancelled-forced");
    const naturallyCompleted = await client.cancel(accepted.dispatchId);
    assert.equal(naturallyCompleted.operation, "completed");
    assert.deepEqual(terminals, ["cancelled", "completed"]);
    assert.deepEqual(failures, []);
    await client.shutdown();
  } finally {
    await client.shutdown().catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("client rejects a capability-summary missing PR1 profile fields or claiming a non-empty delegableAvailable", async () => {
  const root = join(process.cwd(), `.dashboard-dispatch-malformed-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const descriptor = join(root, "descriptor.json");
  const pwsh = resolvePwshPath();
  await writeFile(descriptor, "{}", "utf8");

  async function describeWith(fakeBrokerBody: string): Promise<{ failures: string[]; rejected: boolean }> {
    const script = join(root, `fake-broker-${Date.now()}-${Math.random()}.ps1`);
    await writeFile(script, String.raw`
param([string]$DescriptorPath)
$line = [Console]::In.ReadLine()
$r = $line | ConvertFrom-Json
if ($r.operation -eq 'describe') {
` + fakeBrokerBody + String.raw`
}
# Exit immediately after the single malformed response -- the client is expected to fail closed
# on it and never send a shutdown request, so this script must not block on further stdin input.
`, "utf8");
    const failures: string[] = [];
    const client = new DispatchClient(
      { executablePath: pwsh, scriptPath: script, descriptorPath: descriptor },
      { onBrokerFailure: (failure) => failures.push(failure) },
    );
    let rejected = false;
    try {
      await client.describe("v1:github:9007199254740993", 104, "reviewer");
    } catch {
      rejected = true;
    } finally {
      await client.shutdown().catch(() => {});
    }
    return { failures, rejected };
  }

  try {
    // Missing every PR1 additive field entirely (pre-#105 shape).
    const missingFields = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@()} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(missingFields.rejected, true);
    assert.equal(missingFields.failures.length, 1);

    // Every PR1 field present and well-typed, but delegableAvailable is non-empty -- no delegation
    // policy can exist yet in this release, so the client must treat this as malformed too.
    const nonEmptyDelegable = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@('EnableApprovalVote');provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(nonEmptyDelegable.rejected, true);
    assert.equal(nonEmptyDelegable.failures.length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("client rejects a capability-summary whose legacy capability arrays are malformed", async () => {
  const root = join(process.cwd(), `.dashboard-dispatch-legacy-malformed-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const descriptor = join(root, "descriptor.json");
  const pwsh = resolvePwshPath();
  await writeFile(descriptor, "{}", "utf8");

  async function describeWith(fakeBrokerBody: string): Promise<{ failures: string[]; rejected: boolean }> {
    const script = join(root, `fake-broker-${Date.now()}-${Math.random()}.ps1`);
    await writeFile(script, String.raw`
param([string]$DescriptorPath)
$line = [Console]::In.ReadLine()
$r = $line | ConvertFrom-Json
if ($r.operation -eq 'describe') {
` + fakeBrokerBody + String.raw`
}
# Exit immediately after the single malformed response -- the client is expected to fail closed
# on it and never send a shutdown request, so this script must not block on further stdin input.
`, "utf8");
    const failures: string[] = [];
    const client = new DispatchClient(
      { executablePath: pwsh, scriptPath: script, descriptorPath: descriptor },
      { onBrokerFailure: (failure) => failures.push(failure) },
    );
    let rejected = false;
    try {
      await client.describe("v1:github:9007199254740993", 104, "reviewer");
    } catch {
      rejected = true;
    } finally {
      await client.shutdown().catch(() => {});
    }
    return { failures, rejected };
  }

  try {
    // Legacy `capabilities` is a bare string rather than an array -- the same shape a hand-edited
    // or buggy broker response could plausibly send, and exactly what UI code's .join() assumes
    // will never happen.
    const nonArrayCapabilities = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities='EnableSummaryComment';mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(nonArrayCapabilities.rejected, true);
    assert.equal(nonArrayCapabilities.failures.length, 1);

    // Legacy `mandatoryDenies` is an array, but one item is not a string.
    const nonStringItem = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@(7);dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(nonStringItem.rejected, true);
    assert.equal(nonStringItem.failures.length, 1);

    // Legacy `dynamicConstraints` is a well-typed string array but exceeds the bounded-array
    // item-count limit the parser now enforces uniformly across every capability-name array.
    const oversizedArray = await describeWith(String.raw`
    $items = 1..300 | ForEach-Object { "c$_" }
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@();dynamicConstraints=$items;absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(oversizedArray.rejected, true);
    assert.equal(oversizedArray.failures.length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
