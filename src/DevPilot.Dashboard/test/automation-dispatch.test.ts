import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { BrokerRejectionError, DispatchClient } from "../src/dispatch.js";

const executablePath = execFileSync(process.platform === "win32" ? "where.exe" : "which",
  ["pwsh"], { encoding: "utf8" }).trim().split(/\r?\n/)[0]!;
const script = String.raw`
param([string]$DescriptorPath)
$d = Get-Content $DescriptorPath -Raw | ConvertFrom-Json -AsHashtable
$reads = 0
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $r = $line | ConvertFrom-Json -AsHashtable
  Add-Content $d.log $line
  if ($r.operation -ceq 'shutdown') {
    @{schemaVersion=1;requestId=$r.requestId;operation='shutdown-complete'} | ConvertTo-Json -Compress
    return
  }
  $response = @{schemaVersion=1;requestId=$r.requestId;automationVersion=1;scope='current-launcher'}
  if ($r.operation -ceq 'get-automation-status') {
    $reads++
    $response.operation='automation-status'; $response.available=$true
    $response.agents=@(
      @{role='reviewer';continuous=$true;intervalSeconds=900;state='waiting';canScanNow=$true},
      @{role='review-handler';continuous=$true;intervalSeconds=900;state='scanning';canScanNow=$false}
    )
    switch ($d.mode) {
      'unavailable' {$response.available=$false; $response.scope=$null; $response.agents=@()}
      'version' {$response.automationVersion=2}
      'unknown-top' {$response.processId=42}
      'unknown-agent' {$response.agents[0].processId=42}
      'unknown-role' {$response.agents[0].role='Reviewer'}
      'duplicate-role' {$response.agents[1].role='reviewer'}
      'too-many' {$response.agents+=@{role='reviewer';continuous=$true;intervalSeconds=900;state='waiting';canScanNow=$true}}
      'empty-available' {$response.agents=@()}
      'bad-available' {$response.available='true'}
      'unavailable-nonempty' {$response.available=$false; $response.scope=$null}
      'unavailable-scope' {$response.available=$false; $response.agents=@()}
      'foreign-scope' {$response.scope='same-user'}
      'low-interval' {$response.agents[0].intervalSeconds=29}
      'high-interval' {$response.agents[0].intervalSeconds=86401}
      'float-interval' {$response.agents[0].intervalSeconds=900.5}
      'string-interval' {$response.agents[0].intervalSeconds='900'}
      'once-interval' {$response.agents[0].continuous=$false; $response.agents[0].canScanNow=$false}
      'once-wake' {$response.agents[0].continuous=$false; $response.agents[0].intervalSeconds=$null}
      'scanning-wake' {$response.agents[0].state='scanning'}
      'unknown-state' {$response.agents[0].state='idle'}
      'bad-wake-type' {$response.agents[0].canScanNow=1}
      'source-failure' {
        if ($reads -gt 1) {
          $response=@{schemaVersion=1;requestId=$r.requestId;operation='rejected';code='launcher-control-lost';detail='fixture source unavailable'}
        }
      }
    }
  } elseif ($r.operation -ceq 'scan-now') {
    $response.operation='scan-now-result'
    $response.results=@(@{role='reviewer';outcome='requested'},@{role='review-handler';outcome='already-running'})
    switch ($d.mode) {
      'mismatched-results' {$response.results=@(@{role='reviewer';outcome='requested'})}
      'scan-version' {$response.automationVersion=2}
      'scan-role' {$response.results[0].role='foreign'}
      'scan-duplicate' {$response.results[1].role='reviewer'}
      'scan-field' {$response.results[0].pid=42}
      'scan-scope' {$response.scope='same-user'}
      'scan-outcome' {$response.results[0].outcome='completed'}
      'scan-empty' {$response.results=@()}
    }
  } else { throw 'Unexpected test request.' }
  $response | ConvertTo-Json -Depth 10 -Compress
}
`;

async function fixture(mode: string, action: (client: DispatchClient, log: string) => Promise<void>): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "devpilot-auto-protocol-"));
  const scriptPath = join(root, "broker.ps1");
  const descriptorPath = join(root, "descriptor.json");
  const log = join(root, "requests.jsonl");
  await writeFile(scriptPath, script);
  await writeFile(descriptorPath, JSON.stringify({ mode, log }));
  const client = new DispatchClient({ executablePath, scriptPath, descriptorPath });
  try { await action(client, log); }
  finally {
    await client.shutdown();
    await new Promise((resolve) => setTimeout(resolve, 100));
    await rm(root, { recursive: true, force: true });
  }
}

test("automation polls are explicit, read-only, coalesced, and scan requests carry no authority fields", async () => {
  await fixture("normal", async (client, log) => {
    await assert.rejects(client.scanNow(), /automation-unavailable/);
    const first = client.getAutomationStatus();
    const second = client.getAutomationStatus();
    assert.equal(first, second, "at most one status poll is in flight");
    const status = await first;
    assert.equal(status.available, true);
    assert.equal(status.agents[0]?.intervalSeconds, 900);
    const requestsBeforeScan = (await readFile(log, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.equal(requestsBeforeScan.length, 1, "polling does not schedule scans");
    const result = await client.scanNow();
    assert.deepEqual(result.results.map((item) => item.outcome), ["requested", "already-running"]);
    const requests = (await readFile(log, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.deepEqual(requests.map((r) => r.operation), ["get-automation-status", "scan-now"]);
    for (const request of requests) assert.deepEqual(Object.keys(request).sort(), ["operation", "requestId", "schemaVersion"]);
  });
});

test("unavailable automation stays unknown rather than inventing stopped roles, and refuses scan locally", async () => {
  await fixture("unavailable", async (client, log) => {
    const status = await client.getAutomationStatus();
    assert.equal(status.available, false);
    assert.equal(status.scope, null);
    assert.deepEqual(status.agents, []);
    await assert.rejects(client.scanNow(), /automation-unavailable/);
    assert.equal((await readFile(log, "utf8")).trim().split(/\r?\n/).length, 1);
  });
});

test("status source failure clears previously verified automation availability", async () => {
  await fixture("source-failure", async (client, log) => {
    await client.getAutomationStatus();
    await assert.rejects(client.getAutomationStatus(), (error: unknown) =>
      error instanceof BrokerRejectionError && error.code === "launcher-control-lost");
    await assert.rejects(client.scanNow(), /automation-unavailable/);
    assert.equal((await readFile(log, "utf8")).trim().split(/\r?\n/).length, 2);
  });
});

for (const mode of ["version", "unknown-top", "unknown-agent", "unknown-role", "duplicate-role", "too-many",
  "empty-available", "bad-available", "unavailable-nonempty", "unavailable-scope", "foreign-scope", "low-interval",
  "high-interval", "float-interval", "string-interval", "once-interval", "once-wake", "scanning-wake",
  "unknown-state", "bad-wake-type"]) {
  test(`automation status rejects ${mode}`, async () => {
    await fixture(mode, async (client) => {
      await assert.rejects(client.getAutomationStatus(), /invalid protocol frame/);
      await assert.rejects(client.scanNow(), /automation-unavailable/);
    });
  });
}

for (const mode of ["mismatched-results", "scan-version", "scan-role", "scan-duplicate", "scan-field",
  "scan-scope", "scan-outcome", "scan-empty"]) {
  test(`scan-now rejects ${mode} instead of claiming a wake`, async () => {
    await fixture(mode, async (client) => {
      await client.getAutomationStatus();
      await assert.rejects(client.scanNow(), /do not match|invalid protocol frame/);
      await assert.rejects(client.scanNow(), /automation-unavailable/);
    });
  });
}

test("completed periodic polls leave no pending requests, drafts, or growing client correlations", async () => {
  await fixture("normal", async (client, log) => {
    for (let index = 0; index < 256; index++) {
      assert.equal((await client.getAutomationStatus()).agents.length, 2);
    }
    for (const name of ["pending", "preparedTargets", "scheduledTargets", "scheduledDispatches"]) {
      const entries: unknown = Reflect.get(client, name);
      assert.ok(entries instanceof Map);
      assert.equal(entries.size, 0, `${name} must not accumulate read-only polling state`);
    }
    assert.equal(Reflect.get(client, "automationStatusRequest"), undefined);
    assert.deepEqual(Reflect.get(client, "automationRoles"), ["reviewer", "review-handler"]);
    const requests = (await readFile(log, "utf8")).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.equal(requests.length, 256);
    assert.ok(requests.every((request) => request.operation === "get-automation-status"));
  });
});
