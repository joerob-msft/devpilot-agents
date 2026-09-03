import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { DispatchClient, DISPATCH_PROTOCOL_MAX_BYTES } from "../src/dispatch.js";

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

test("production client correlates describe, dispatch, cancel, and shutdown under pwsh", async (context) => {
  if (process.platform !== "win32") {
    context.skip("local fixture uses the Windows pwsh path; CI exercises its platform pwsh");
    return;
  }
  const root = join(process.cwd(), `.dashboard-dispatch-${process.pid}-${Date.now()}`);
  await mkdir(root, { recursive: false });
  const script = join(root, "fake-broker.ps1");
  const descriptor = join(root, "descriptor.json");
  const pwsh = join(process.env.ProgramFiles ?? "C:\\Program Files", "PowerShell", "7", "pwsh.exe");
  await writeFile(descriptor, "{}", "utf8");
  await writeFile(script, String.raw`
param([string]$DescriptorPath)
$cancelCount = 0
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $r = $line | ConvertFrom-Json
  if ($r.operation -eq 'describe') {
    @{schemaVersion=1;requestId=$r.requestId;operation='capability-summary';dispatchDraftId='11111111-1111-4111-8111-111111111111';repositoryIdentity=@{schemaVersion=1;provider='GitHub';repositoryId='9007199254740993';organization='contoso';project='';repositoryName='repo';slug='contoso/repo';key='v1:github:9007199254740993';verifiedAtUtc='2026-09-03T00:00:00Z';verified=$true;dispatchEligible=$true};prSnapshot=@{schemaVersion=1;pullRequestId=104;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='ada';title='test'};capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@('EnableSummaryComment');mandatoryDenies=@('EnableApprovalVote');dynamicConstraints=@()} | ConvertTo-Json -Compress -Depth 10
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
