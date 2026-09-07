import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  BrokerRejectionError, DispatchClient, type RunProgress, type ScheduledDispatchAccepted,
} from "../src/dispatch.js";

const executablePath = execFileSync(process.platform === "win32" ? "where.exe" : "which",
  ["pwsh"], { encoding: "utf8" }).trim().split(/\r?\n/)[0]!;
const queueId = "22222222-2222-4222-8222-222222222222";
const brokerFixture = String.raw`
param([string]$DescriptorPath)
$d = Get-Content $DescriptorPath -Raw | ConvertFrom-Json -AsHashtable
if ($d.mode -in @('automatic-startup-failed', 'automatic-worker-failed')) {
  @{schemaVersion=1;requestId='00000000-0000-0000-0000-000000000000';operation='rejected'
    code=$d.mode;detail='Automatic reviewer worker exited with code 17; this launcher is stopping.'} |
    ConvertTo-Json -Compress
  exit 17
}
$identity = @{schemaVersion=1;provider='GitHub';repositoryId='114';organization='fixture';project='';repositoryName='repo';slug='fixture/repo';key='v1:github:114';verifiedAtUtc='2026-09-05T00:00:00Z';verified=$true;dispatchEligible=$true}
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $r = $line | ConvertFrom-Json -AsHashtable
  Add-Content $d.log $line
  $response = @{schemaVersion=1;requestId=$r.requestId}
  switch ($r.operation) {
    'describe' {
      $response += @{
        operation='capability-summary';role='reviewer';repositoryIdentity=$identity
        dispatchDraftId='11111111-1111-4111-8111-111111111111'
        prSnapshot=@{schemaVersion=1;pullRequestId=116;sourceCommit=('a'*40);sourceRef='feature';targetRef='main';active=$true;draft=$false;author='fixture';title='fixture'}
        capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);capabilities=@();mandatoryDenies=@('EnableApprovalVote')
        dynamicConstraints=@();absoluteDenies=@();allowedManualCapabilities=@();delegableAvailable=@()
        provenance=@{};killSwitchActive=$false;killSwitchExpiresAtUtc=$null
      }
      if ($d.mode -ne 'legacy') { $response.scheduling=@{version=1;scope='current-launcher'} }
      if ($d.mode -eq 'future') { $response.scheduling.version=2 }
    }
    'prepare-run' {
      $response += @{operation='run-prepared';schedulingVersion=1;scope='current-launcher';confirmationToken=('a'*48)
        expiresAtUtc=[DateTime]::UtcNow.AddMinutes(1).ToString('o');repositoryKey=$r.repositoryKey
        pullRequestId=$r.pullRequestId;role=$r.role;mode=$r.mode
        conflict=@{kind='automatic';workId='33333333-3333-4333-8333-333333333333'
          generation='44444444-4444-4444-8444-444444444444';pullRequestId=114}
      }
      if ($d.mode -eq 'wrong-target') { $response.pullRequestId=115 }
      if ($d.mode -eq 'foreign-scope') { $response.scope='same-user' }
      if ($d.mode -eq 'bad-generation') { $response.conflict.generation=42 }
    }
    'confirm-run' {
      $response += @{operation='run-queued';schedulingVersion=1;queueId='22222222-2222-4222-8222-222222222222';mode='next'}
    }
    'cancel-queued' {
      $response += @{operation='queue-cancelled';schedulingVersion=1;queueId=$r.queueId}
      if ($d.mode -eq 'wrong-cancel') { $response.queueId='55555555-5555-4555-8555-555555555555' }
    }
    'shutdown' {
      $response.operation='shutdown-complete'
      $response | ConvertTo-Json -Depth 10 -Compress
      return
    }
    default { throw 'Unexpected fixture operation.' }
  }
  $response | ConvertTo-Json -Depth 10 -Compress
  if ($r.operation -eq 'confirm-run') {
    @{schemaVersion=1;requestId=$r.requestId;operation='run-progress';schedulingVersion=1;queueId='22222222-2222-4222-8222-222222222222';state='queued';code=''} | ConvertTo-Json -Compress
    @{schemaVersion=1;requestId=$r.requestId;operation='accepted';queueId='22222222-2222-4222-8222-222222222222'
      dispatchId='66666666-6666-4666-8666-666666666666';repositoryIdentity=$identity;pullRequestId=116;role='reviewer'
      capabilityPolicyDigest=('b'*64);prStateFingerprint=('c'*64);childProcessId=$PID;eventLogPath=(Join-Path $PSScriptRoot 'events.jsonl')
    } | ConvertTo-Json -Depth 10 -Compress
  }
}
`;

async function fixture(mode: string, action: (client: DispatchClient, log: string) => Promise<void>): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "devpilot-scheduling-protocol-"));
  const scriptPath = join(root, "broker.ps1");
  const descriptorPath = join(root, "descriptor.json");
  const log = join(root, "requests.jsonl");
  await writeFile(scriptPath, brokerFixture);
  await writeFile(descriptorPath, JSON.stringify({ mode, log }));
  const client = new DispatchClient({ executablePath, scriptPath, descriptorPath });
  try { await action(client, log); }
  finally {
    await client.shutdown();
    // A malformed-response failure closes stdin; the fake broker has no descendants.
    await new Promise((resolve) => setTimeout(resolve, 150));
    await rm(root, { recursive: true, force: true });
  }
}

test("busy protocol separates inert preparation from exact confirmation and routes same-chunk acceptance", async () => {
  await fixture("normal", async (client, log) => {
    const progress: RunProgress[] = [];
    const accepted: ScheduledDispatchAccepted[] = [];
    client.subscribeSchedule((event) => progress.push(event));
    client.subscribeScheduledAccepted((event) => accepted.push(event));
    const summary = await client.describe("v1:github:114", 116, "reviewer");
    const prepared = await client.prepareRun(summary, "next", "bounded context");
    let requests = (await readFile(log, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.deepEqual(requests.map((r) => r.operation), ["describe", "prepare-run"]);
    assert.equal("dispatchDraftId" in requests[1], false, "consumed drafts cannot be retried");
    await assert.rejects(client.confirmRun({ ...prepared, mode: "replace" }), (error: unknown) =>
      error instanceof BrokerRejectionError && error.code === "schedule-stale");
    const queued = await client.confirmRun(prepared);
    assert.equal(queued.queueId, queueId);
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(progress[0]?.state, "queued");
    assert.equal(accepted[0]?.queueId, queueId);
    assert.equal(accepted[0]?.pullRequestId, 116);
    await assert.rejects(client.confirmRun(prepared), (error: unknown) =>
      error instanceof BrokerRejectionError && error.code === "schedule-stale");
    assert.equal((await client.cancelQueued(queueId)).queueId, queueId);
    requests = (await readFile(log, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    const confirmation = requests.find((r) => r.operation === "confirm-run");
    assert.equal(confirmation.expectedWorkId, prepared.conflict.workId);
    assert.equal(confirmation.expectedGeneration, prepared.conflict.generation);
    assert.equal(confirmation.confirmationToken, prepared.confirmationToken);
    assert.equal("operatorPrompt" in confirmation, false);
  });
});

for (const mode of ["legacy", "future"]) {
  test(`${mode} launchers do not expose fake busy scheduling controls`, async () => {
    await fixture(mode, async (client, log) => {
      const summary = await client.describe("v1:github:114", 116, "reviewer");
      assert.equal(summary.scheduling, undefined);
      await assert.rejects(client.prepareRun(summary, "replace", ""), (error: unknown) =>
        error instanceof BrokerRejectionError && error.code === "scheduling-unavailable");
      assert.equal((await readFile(log, "utf8")).trim().split(/\r?\n/).length, 1);
    });
  });
}

for (const mode of ["wrong-target", "foreign-scope", "bad-generation"]) {
  test(`busy protocol rejects ${mode} preparation instead of authorizing cancellation`, async () => {
    await fixture(mode, async (client) => {
      const summary = await client.describe("v1:github:114", 116, "reviewer");
      await assert.rejects(client.prepareRun(summary, "next", ""), /does not match|invalid protocol/);
    });
  });
}

test("queued cancellation validates the exact pending intent echo", async () => {
  await fixture("wrong-cancel", async (client) => {
    await assert.rejects(client.cancelQueued(queueId), /different queued intent/);
  });
});

for (const code of ["automatic-startup-failed", "automatic-worker-failed"]) {
  test(`unsolicited ${code} fails pending calls with actionable role and exit status`, async () => {
    await fixture(code, async (client) => {
      await assert.rejects(client.describe("v1:github:114", 116, "reviewer"),
        new RegExp(`${code}:.*reviewer.*17`));
    });
  });
}
