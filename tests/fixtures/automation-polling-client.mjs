import assert from "node:assert/strict";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DispatchClient, BrokerRejectionError } from "./dispatch.ts";

const args = process.argv.slice(2);
const value = (flag) => args[args.indexOf(flag) + 1];
const root = process.env.DEVPILOT_SCHEDULING_FIXTURE;
assert.ok(root, "an isolated fixture root is required");
const config = JSON.parse(readFileSync(join(root, "scenario.json"), "utf8"));
const mode = config.testMode;
const roles = ["reviewer", "review-handler"];
let failure;
const accepted = [];
const terminal = [];
const client = new DispatchClient({
  executablePath: value("--broker-executable"), scriptPath: value("--broker-script"),
  descriptorPath: value("--broker-descriptor"),
}, { onBrokerFailure: (message) => { failure = message; }, onScheduledAccepted: (event) => accepted.push(event) });
client.child.stderr.on("data", (bytes) => appendFileSync(join(root, "broker.log"), bytes));
client.subscribeTerminal((event) => terminal.push(event));
const mark = (name) => writeFileSync(join(root, name), "fixture");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function wait(predicate, label) {
  const deadline = Date.now() + 35_000;
  while (!await predicate()) {
    if (failure) throw new Error(failure);
    assert.ok(Date.now() < deadline, label);
    await sleep(40);
  }
}
async function stateIs(state) {
  return (await client.getAutomationStatus()).agents.every((agent) => agent.state === state);
}
try {
  await assert.rejects(client.scanNow(), (error) => error instanceof BrokerRejectionError && error.code === "automation-unavailable");
  if (mode === "unavailable") {
    assert.deepEqual((await client.getAutomationStatus()).agents, []);
    const status = await client.getAutomationStatus();
    assert.equal(status.available, false);
    assert.equal(status.scope, null);
    await assert.rejects(client.scanNow(), /automation-unavailable/);
  } else {
    await wait(() => roles.every((role) => existsSync(join(root, `${role}.scan-1`))), "initial immediate scan");
    const original = roles.map((role) => JSON.parse(readFileSync(join(root, `${role}.launch`), "utf8")));
    const descriptorBefore = readFileSync(value("--broker-descriptor"), "utf8");
    const scanning = await client.getAutomationStatus();
    assert.deepEqual(scanning.agents.map((a) => a.role).sort(), [...roles].sort());
    assert.ok(scanning.agents.every((a) => a.state === "scanning" && !a.canScanNow));
    assert.ok(scanning.agents.every((a) => a.continuous === (mode !== "once") && a.intervalSeconds === (mode === "once" ? null : 900)));
    assert.ok(original.every((a) => !a.finding && !a.replies && !a.summary), "PreviewOnly remains write-free");
    if (mode.startsWith("manual-")) {
      const summary = await client.describe("v1:github:114", 116, "reviewer");
      const prepared = await client.prepareRun(summary, mode === "manual-replace" ? "replace" : "next", "isolated scheduling context");
      await client.confirmRun(prepared);
      const status = await client.getAutomationStatus();
      assert.equal(status.agents.find((a) => a.role === "reviewer").state, "paused");
      assert.equal((await client.scanNow()).results.find((r) => r.role === "reviewer").outcome, "manual-priority");
      if (mode !== "manual-replace") mark("reviewer.finish-1");
      if (mode === "manual-poll") {
        await wait(() => existsSync(join(root, "manual-startup-wait")), "manual startup barrier");
        assert.equal(accepted.length, 0);
        const duringStartup = await client.getAutomationStatus();
        assert.equal(duringStartup.agents.find((agent) => agent.role === "reviewer").state, "paused");
      }
      await wait(() => accepted.length === 1 && existsSync(join(root, "manual-started")), "manual turn wins");
      assert.equal((await client.scanNow()).results.find((r) => r.role === "reviewer").outcome, "manual-priority");
      assert.equal(existsSync(join(root, "reviewer.scan-2")), false);
      mark("manual-release");
      await wait(() => terminal.some((event) => event.dispatchId === accepted[0].dispatchId), "manual fixture completion");
    } else {
      assert.ok((await client.scanNow()).results.every((r) => r.outcome === (mode === "once" ? "unavailable" : "already-running")));
      for (const role of roles) mark(`${role}.finish-1`);
      if (mode === "once") {
        await wait(() => stateIs("stopped"), "Once workers stop");
        assert.ok((await client.scanNow()).results.every((r) => r.outcome === "unavailable"));
        assert.equal(roles.some((role) => existsSync(join(root, `${role}.scan-2`))), false);
      } else {
        await wait(() => stateIs("waiting"), "owned workers wait");
        if (mode === "natural") await sleep(950);
        assert.ok((await client.scanNow()).results.every((r) => ["requested", "already-running"].includes(r.outcome)));
        await wait(() => roles.every((role) => existsSync(join(root, `${role}.scan-2`))), "wake both roles before 900 seconds");
        assert.ok((await client.scanNow()).results.every((r) => r.outcome === "already-running"));
        for (const role of roles) mark(`${role}.finish-2`);
        await wait(() => stateIs("waiting"), "next wait is fresh");
        await sleep(mode === "natural" ? 150 : 500);
        assert.equal(roles.some((role) => existsSync(join(root, `${role}.scan-3`))), false, "no wake spills into the next interval");
        assert.ok((await client.getAutomationStatus()).agents.every((a) => a.canScanNow));
      }
    }
    assert.equal(readFileSync(value("--broker-descriptor"), "utf8"), descriptorBefore, "polling/wake cannot rewrite any automatic capability");
  }
  writeFileSync(join(root, "verified"), "polling fixture passed");
} finally {
  await client.shutdown();
}
