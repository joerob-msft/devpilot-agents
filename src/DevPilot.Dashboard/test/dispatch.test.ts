import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { DispatchClient, DISPATCH_PROTOCOL_MAX_BYTES, type CapabilityProfile, type CapabilitySummary } from "../src/dispatch.js";

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
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@('EnableSummaryComment');mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@('EnableFindingComments','EnableSummaryComment','EnableThreadReplies');delegableAvailable=@();killSwitchActive=$false;provenance=@{EnableFindingComments='operational-default';EnableSummaryComment='operational-default';EnableThreadReplies='operational-default';EnableApprovalVote='operational-default'}} | ConvertTo-Json -Compress -Depth 10
  } elseif ($r.operation -eq 'profile') {
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-profile';role='reviewer';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilities=@('EnableSummaryComment');mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@('EnableFindingComments','EnableSummaryComment','EnableThreadReplies');delegableAvailable=@();killSwitchActive=$false;provenance=@{EnableFindingComments='operational-default';EnableSummaryComment='operational-default';EnableThreadReplies='operational-default';EnableApprovalVote='operational-default'}} | ConvertTo-Json -Compress -Depth 10
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

    // Positive broker-authored role test (issue #105): profile() is the Settings TUI's dedicated,
    // side-effect-free counterpart to describe(). Its response must carry the broker's own role
    // (never client-stamped) and must never carry dispatch/draft-only fields.
    const profile = await client.profile("v1:github:9007199254740993", 104, "reviewer");
    assert.equal(profile.operation, "capability-profile");
    assert.equal(profile.role, "reviewer");
    assert.deepEqual(profile.capabilities, ["EnableSummaryComment"]);
    assert.ok(!("dispatchDraftId" in profile), "profile responses must never carry a dispatchDraftId");
    assert.ok(!("capabilityPolicyDigest" in profile), "profile responses must never carry a capabilityPolicyDigest");
    assert.ok(!("prStateFingerprint" in profile), "profile responses must never carry a prStateFingerprint");

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

test("client accepts a legacy capability-summary missing PR1/2/3-additive fields via safe defaults, but still fails closed on malformed or non-empty values", async () => {
  const root = join(process.cwd(), `.dashboard-dispatch-malformed-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const descriptor = join(root, "descriptor.json");
  const pwsh = resolvePwshPath();
  await writeFile(descriptor, "{}", "utf8");

  async function describeWith(fakeBrokerBody: string): Promise<{ failures: string[]; rejected: boolean; summary: CapabilitySummary | undefined }> {
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
    let summary: CapabilitySummary | undefined;
    try {
      summary = await client.describe("v1:github:9007199254740993", 104, "reviewer");
    } catch {
      rejected = true;
    } finally {
      await client.shutdown().catch(() => {});
    }
    return { failures, rejected, summary };
  }

  try {
    // (4a) A legacy schemaVersion-1 broker that predates PR1/2/3 entirely omits every additive
    // field from the wire -- schemaVersion never bumps for these additions, so this shape is still
    // legal. It must parse successfully with the documented safe defaults, and editingAvailable
    // must be false (this broker cannot support narrowing/kill-switch editing at all).
    const legacy = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@()} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(legacy.rejected, false);
    assert.ok(legacy.summary, "expected a parsed legacy capability-summary");
    assert.deepEqual(legacy.summary?.absoluteDenies, []);
    assert.deepEqual(legacy.summary?.allowedManualCapabilities, []);
    assert.deepEqual(legacy.summary?.delegableAvailable, []);
    assert.deepEqual(Object.entries(legacy.summary?.provenance ?? { unexpected: true }), []);
    assert.equal(legacy.summary?.killSwitchActive, false);
    assert.equal(legacy.summary?.killSwitchExpiresAtUtc, null);
    assert.equal(legacy.summary?.editingAvailable, false);

    // (4b) A full modern record (every additive field present, including the new
    // killSwitchExpiresAtUtc) parses with editingAvailable=true.
    const modern = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@('EnableSummaryComment');delegableAvailable=@();killSwitchActive=$true;killSwitchExpiresAtUtc='2026-09-03T17:00:00Z';provenance=@{EnableSummaryComment='kill-switch'}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(modern.rejected, false);
    assert.equal(modern.summary?.editingAvailable, true);
    assert.equal(modern.summary?.killSwitchActive, true);
    assert.equal(modern.summary?.killSwitchExpiresAtUtc, "2026-09-03T17:00:00Z");

    // Every PR1 field present and well-typed, but delegableAvailable is non-empty -- no delegation
    // policy can exist yet in this release, so the client must treat this as malformed too.
    const nonEmptyDelegable = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@('EnableApprovalVote');killSwitchActive=$false;provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(nonEmptyDelegable.rejected, true);
    assert.equal(nonEmptyDelegable.failures.length, 1);

    // (4c) A malformed (wrong-type) additive field must still throw even though it's one of the
    // fields that is otherwise allowed to be absent -- the safe-defaulting above only covers
    // genuine absence, never corruption.
    const malformedAdditive = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();allowedManualCapabilities='not-an-array'} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(malformedAdditive.rejected, true);
    assert.equal(malformedAdditive.failures.length, 1);
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
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities='EnableSummaryComment';mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();killSwitchActive=$false;provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(nonArrayCapabilities.rejected, true);
    assert.equal(nonArrayCapabilities.failures.length, 1);

    // Legacy `mandatoryDenies` is an array, but one item is not a string.
    const nonStringItem = await describeWith(String.raw`
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@(7);dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();killSwitchActive=$false;provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(nonStringItem.rejected, true);
    assert.equal(nonStringItem.failures.length, 1);

    // Legacy `dynamicConstraints` is a well-typed string array but exceeds the bounded-array
    // item-count limit the parser now enforces uniformly across every capability-name array.
    const oversizedArray = await describeWith(String.raw`
    $items = 1..300 | ForEach-Object { "c$_" }
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';role='reviewer';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@();dynamicConstraints=$items;absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();killSwitchActive=$false;provenance=@{}} | ConvertTo-Json -Compress -Depth 10
`);
    assert.equal(oversizedArray.rejected, true);
    assert.equal(oversizedArray.failures.length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("client accepts every known capability provenance value and rejects an unrecognized one", async () => {
  const root = join(process.cwd(), `.dashboard-dispatch-provenance-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const descriptor = join(root, "descriptor.json");
  const pwsh = resolvePwshPath();
  await writeFile(descriptor, "{}", "utf8");
  const validIdentity = "@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';" +
    "project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';" +
    "verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true}";
  const validPrSnapshot = "@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';" +
    "targetRef='main';active=$true;draft=$false;author='ada';title='test'}";

  async function profileWithProvenance(
    provenancePs1: string,
    killSwitchExpiresAtUtcPs1 = "$null",
  ): Promise<{ failures: string[]; profile: CapabilityProfile | undefined }> {
    const script = join(root, `fake-broker-${Date.now()}-${Math.random()}.ps1`);
    await writeFile(script, String.raw`
param([string]$DescriptorPath)
$line = [Console]::In.ReadLine()
$r = $line | ConvertFrom-Json
if ($r.operation -eq 'profile') {
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-profile';role='reviewer';repositoryIdentity=${validIdentity};prSnapshot=${validPrSnapshot};capabilities=@();mandatoryDenies=@();dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();killSwitchActive=$false;killSwitchExpiresAtUtc=` + killSwitchExpiresAtUtcPs1 + String.raw`;provenance=` +
      provenancePs1 + String.raw`} | ConvertTo-Json -Compress -Depth 10
}
# Exit immediately after the single response, matching the other single-shot fixtures in this file.
`, "utf8");
    const failures: string[] = [];
    const client = new DispatchClient(
      { executablePath: pwsh, scriptPath: script, descriptorPath: descriptor },
      { onBrokerFailure: (failure) => failures.push(failure) },
    );
    let profile: CapabilityProfile | undefined;
    try {
      profile = await client.profile("v1:github:9007199254740993", 104, "reviewer");
    } catch {
      // left undefined; caller asserts on failures/profile as appropriate
    } finally {
      await client.shutdown().catch(() => {});
    }
    return { failures, profile };
  }

  try {
    // Every known provenance value (the operational-default ceiling, all four outside-repository
    // capability-override store scopes, and the PR3 kill-switch emergency lever) must parse
    // through unchanged.
    const allKnown = await profileWithProvenance(
      "@{ceilingCap='operational-default';machineCap='machine';userCap='user';" +
      "worktreeCap='repo-worktree';prCap='pr';killSwitchCap='kill-switch'}",
    );
    // The single-shot fixture exits right after writing its one response (matching the other
    // fixtures in this file), which the client reports as one unrequested-exit broker failure --
    // orthogonal to whether the in-flight profile() call itself resolved successfully.
    assert.equal(allKnown.failures.length, 1);
    assert.ok(allKnown.profile, "expected a parsed capability-profile");
    assert.equal(allKnown.profile?.provenance.ceilingCap, "operational-default");
    assert.equal(allKnown.profile?.provenance.machineCap, "machine");
    assert.equal(allKnown.profile?.provenance.userCap, "user");
    assert.equal(allKnown.profile?.provenance.worktreeCap, "repo-worktree");
    assert.equal(allKnown.profile?.provenance.prCap, "pr");
    assert.equal(allKnown.profile?.provenance.killSwitchCap, "kill-switch");
    assert.equal(allKnown.profile?.killSwitchExpiresAtUtc, null);

    // killSwitchExpiresAtUtc must likewise round-trip a real ISO-8601 UTC string unchanged (the
    // kill switch's short TTL, PR3 review item).
    const withExpiry = await profileWithProvenance("@{soloCap='machine'}", "'2026-09-03T17:00:00Z'");
    assert.equal(withExpiry.profile?.killSwitchExpiresAtUtc, "2026-09-03T17:00:00Z");

    // An unrecognized provenance value must still be rejected outright rather than silently
    // accepted -- the runtime validator is the trust boundary for this union, not just its type.
    const unknown = await profileWithProvenance("@{someCap='admin-override'}");
    assert.equal(unknown.profile, undefined);
    assert.equal(unknown.failures.length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("client rejects a capability-summary or capability-profile with a missing or mismatched on-wire role", async () => {
  const root = join(process.cwd(), `.dashboard-dispatch-role-malformed-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const descriptor = join(root, "descriptor.json");
  const pwsh = resolvePwshPath();
  await writeFile(descriptor, "{}", "utf8");
  const validIdentity = "@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';" +
    "project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';" +
    "verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true}";
  const validPrSnapshot = "@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';" +
    "targetRef='main';active=$true;draft=$false;author='ada';title='test'}";

  async function requestWith(
    operation: "describe" | "profile",
    responseOperation: "capability-summary" | "capability-profile",
    roleAssignment: string,
  ): Promise<{ failures: string[]; rejected: boolean }> {
    const draftFields = responseOperation === "capability-summary"
      ? "dispatchDraftId='11111111-1111-4111-8111-111111111111';capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);"
      : "";
    const script = join(root, `fake-broker-${Date.now()}-${Math.random()}.ps1`);
    await writeFile(script, String.raw`
param([string]$DescriptorPath)
$line = [Console]::In.ReadLine()
$r = $line | ConvertFrom-Json
if ($r.operation -eq '` + operation + String.raw`') {
    @{schemaVersion=1;requestId=$r.requestId;operation='` + responseOperation + `';` + roleAssignment + draftFields +
      `repositoryIdentity=${validIdentity};prSnapshot=${validPrSnapshot};capabilities=@();mandatoryDenies=@();` +
      `dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@();killSwitchActive=$false;provenance=@{}} |` +
      String.raw` ConvertTo-Json -Compress -Depth 10
}
# Exit immediately after the single response (matching the other malformed-field fixtures in this
# file) -- a looping script that only exits on an explicit shutdown would instead orphan the child
# process forever whenever the client's own shutdown() short-circuits (e.g. once already closed by
# a connection-level broker failure), since nothing would ever be left to send it one.
`, "utf8");
    const failures: string[] = [];
    const client = new DispatchClient(
      { executablePath: pwsh, scriptPath: script, descriptorPath: descriptor },
      { onBrokerFailure: (failure) => failures.push(failure) },
    );
    let rejected = false;
    try {
      if (operation === "describe") {
        await client.describe("v1:github:9007199254740993", 104, "reviewer");
      } else {
        await client.profile("v1:github:9007199254740993", 104, "reviewer");
      }
    } catch {
      rejected = true;
    } finally {
      await client.shutdown().catch(() => {});
    }
    return { failures, rejected };
  }

  try {
    // Missing role entirely (pre-#105 shape) on both operations.
    const summaryMissingRole = await requestWith("describe", "capability-summary", "");
    assert.equal(summaryMissingRole.rejected, true);
    const profileMissingRole = await requestWith("profile", "capability-profile", "");
    assert.equal(profileMissingRole.rejected, true);

    // A well-typed but unknown role value fails the runtime reviewer|review-handler check.
    const unknownRole = await requestWith("describe", "capability-summary", "role='auditor';");
    assert.equal(unknownRole.rejected, true);

    // A valid, known role that simply does not match what was requested must still be rejected --
    // the client never trusts an on-wire role pairing the request didn't itself produce, and this
    // is the only place that guarantee is enforced now that the broker's role is authoritative.
    const mismatchedSummaryRole = await requestWith("describe", "capability-summary", "role='review-handler';");
    assert.equal(mismatchedSummaryRole.rejected, true);
    const mismatchedProfileRole = await requestWith("profile", "capability-profile", "role='review-handler';");
    assert.equal(mismatchedProfileRole.rejected, true);

    // Missing/unknown role fails runtime parsing itself (roleField), which routes through the
    // client's connection-level broker-failure reporting exactly like the other malformed-field
    // tests in this file.
    for (const result of [summaryMissingRole, profileMissingRole, unknownRole]) {
      assert.equal(result.failures.length, 1);
    }
    // A valid-but-mismatched role parses successfully (it IS a known role): describe()/profile()'s
    // own request/response pairing check rejects that single call regardless of whether the fake
    // broker's natural process exit also happens to race a connection-level broker-failure report,
    // so only `rejected` (not `failures.length`) is a meaningful, deterministic assertion here.
    assert.equal(mismatchedSummaryRole.rejected, true);
    assert.equal(mismatchedProfileRole.rejected, true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
