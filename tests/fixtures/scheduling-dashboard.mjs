import assert from "node:assert/strict";
import { appendFileSync, existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DispatchClient, BrokerRejectionError } from "./dispatch.ts";

const args = process.argv.slice(2);
const value = (name) => args[args.indexOf(name) + 1];
const root = process.env.DEVPILOT_SCHEDULING_FIXTURE;
assert.ok(root, "an isolated fixture root is required");
const config = JSON.parse(readFileSync(join(root, "scenario.json"), "utf8"));
const mode = config.testMode;
const role = config.testRole;
const descriptorPath = value("--broker-descriptor");
const launch = { executablePath: value("--broker-executable"), scriptPath: value("--broker-script"), descriptorPath };
const events = [];
const accepted = [];
let failure;
const client = new DispatchClient(launch, {
  onBrokerFailure: (message) => { failure = message; },
  onSchedule: (event) => events.push(event),
  onScheduledAccepted: (event) => accepted.push(event),
});
client.child.stderr.on("data", (bytes) => appendFileSync(join(root, "broker-fixture.log"), bytes));
const mark = (name) => writeFileSync(join(root, name), "fixture");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate, label, seconds = 35) {
  const deadline = Date.now() + seconds * 1000;
  while (!predicate()) {
    if (failure) throw new Error(`${failure}\n${existsSync(join(root, "broker-fixture.log")) ? readFileSync(join(root, "broker-fixture.log"), "utf8") : ""}`);
    if (Date.now() >= deadline) throw new Error(`timed out: ${label}`);
    await sleep(50);
  }
}
async function expectAutomaticFailure(code) {
  const deadline = Date.now() + 30_000;
  while (!failure && Date.now() < deadline) await sleep(50);
  assert.ok(failure, "automatic failure must reach the client's existing failure hook");
  assert.ok(failure.includes(code), failure);
  assert.ok(failure.includes(role), failure);
  assert.match(failure, /exited.*code (1|17)/);
  assert.equal(events.some((e) => e.state === "resumed"), false, "failed initialization cannot be called resumed");
}
const acquiredFiles = () => readdirSync(root).filter((name) => /^acquired-.*-114$/.test(name));
const launchFiles = () => readdirSync(root).filter((name) => name.startsWith("launched-"));
const terminal = [];
client.subscribeTerminal((event) => terminal.push(event));
try {
  if (mode === "auto-startup-fail" || mode === "real-startup-fail") {
    await expectAutomaticFailure("automatic-startup-failed");
    assert.equal(accepted.length, 0);
  } else if (mode === "foreign") {
    await until(() => existsSync(join(root, "foreign-contended")), "foreign contention");
    const summary = await client.describe("v1:github:114", 116, role);
    await assert.rejects(client.dispatch(summary, "isolated scheduling context"), (error) =>
      error instanceof BrokerRejectionError && error.code === "already-running");
    await assert.rejects(client.prepareRun(summary, "replace", "isolated scheduling context"), (error) =>
      error instanceof BrokerRejectionError && error.code === "not-owner");
    assert.equal(accepted.length, 0);
  } else {
    await until(() => acquiredFiles().length > 0, "owned automatic authority");
    const firstFile = acquiredFiles()[0];
    const generation = firstFile.slice("acquired-".length, -"-114".length);
    const summary = await client.describe("v1:github:114", 116, role);
    assert.equal(summary.scheduling.scope, "current-launcher");
    // The consumed summary remains useful only as the previously consented fingerprint.
    await assert.rejects(client.dispatch(summary, "isolated scheduling context"), (error) =>
      error instanceof BrokerRejectionError && error.code === "already-running");
    const prepared = await client.prepareRun(summary,
      ["replace", "descendant", "ack-descendant", "termination-failed"].includes(mode) ? "replace" : "next", "isolated scheduling context");
    assert.equal(prepared.conflict.kind, "automatic");
    assert.equal(prepared.conflict.generation, generation);
    assert.equal(prepared.conflict.pullRequestId, 114);
    await sleep(250);
    assert.equal(existsSync(join(root, "cancel-observed")), false, "preparation must be inert");
    assert.equal(existsSync(join(root, "manual-started")), false);
    if (mode === "stale") {
      mark("release-114");
      await until(() => existsSync(join(root, `acquired-${generation}-115`)), "successor turn");
      await assert.rejects(client.confirmRun(prepared), (error) =>
        error instanceof BrokerRejectionError && error.code === "schedule-stale");
      assert.equal(existsSync(join(root, "cancel-observed")), false);
    } else {
      const queued = await client.confirmRun(prepared);
      await assert.rejects(client.prepareRun(summary, "next", "isolated scheduling context"), (error) =>
        error instanceof BrokerRejectionError && error.code === "queue-full");
      if (mode === "cancel") {
        assert.equal((await client.cancelQueued(queued.queueId)).queueId, queued.queueId);
        await until(() => events.some((e) => e.state === "resumed"), "cancelled intent released");
        assert.equal(existsSync(join(root, "manual-started")), false);
        assert.equal(launchFiles().length, 1);
      } else if (mode === "eof" || mode === "eof-revalidation") {
        if (mode === "eof-revalidation") {
          mark("delay-revalidation");
          mark("release-114");
          await until(() => existsSync(join(root, "revalidating")), "provider revalidation barrier");
        }
        client.child.stdin.end();
        const deadline = Date.now() + 15_000;
        while (!failure && Date.now() < deadline) await sleep(50);
        assert.ok(failure, "EOF must close the broker, not execute queued intent");
        assert.equal(existsSync(join(root, "manual-started")), false);
      } else if (mode === "termination-failed") {
        await until(() => events.some((e) => e.code === "termination-failed"), "uncertain termination blocked");
        assert.equal(accepted.length, 0);
        assert.equal(launchFiles().length, 1);
        const pid = JSON.parse(readFileSync(join(root, "descendant-pid"), "utf8"));
        process.kill(pid, 0); // Still-owned, still-alive fixture proves no success-shaped fallback.
        await assert.rejects(client.cancelQueued(queued.queueId), (error) =>
          error instanceof BrokerRejectionError && error.code === "not-queued");
      } else if (mode === "shutdown") {
        await client.shutdown();
        // A fresh broker may not replay the closed Watch session or its queued intent.
        let restartFailure;
        const restarted = new DispatchClient(launch, { onBrokerFailure: (message) => { restartFailure = message; } });
        const deadline = Date.now() + 15_000;
        while (!restartFailure && Date.now() < deadline) await sleep(50);
        assert.ok(restartFailure);
        await restarted.shutdown();
        assert.equal(existsSync(join(root, "manual-started")), false);
        assert.equal(launchFiles().length, 1);
      } else {
        if (mode === "source") mark("source-changed");
        if (mode === "policy") {
          const preview = await client.previewNarrowing("v1:github:114", 116, role,
            "machine", "EnableSummaryComment", "off");
          await client.applyNarrowing(preview, "v1:github:114", 116);
        }
        if (mode === "expiry") await sleep(4500);
        if (!["replace", "descendant", "ack-descendant"].includes(mode)) {
          assert.equal(existsSync(join(root, "manual-started")), false);
          mark("release-114");
        }
        if (["source", "expiry", "policy"].includes(mode)) {
          await until(() => events.some((e) => e.state === "blocked"), "changed or expired intent");
          assert.ok(events.some((e) => ["schedule-repreview-required", "schedule-expired"].includes(e.code)));
          assert.equal(existsSync(join(root, "manual-started")), false);
        } else {
          await until(() => accepted.length === 1, "scheduled acceptance");
          await until(() => existsSync(join(root, "manual-started")), "manual workload after proceed");
          assert.equal(accepted[0].queueId, queued.queueId);
          assert.equal(accepted[0].pullRequestId, 116);
          assert.equal(existsSync(join(root, `acquired-${generation}-115`)), false, "manual must precede the next PR");
          assert.equal(launchFiles().length, 1, "automatic admission stays held during manual work");
          if (["replace", "ack-descendant"].includes(mode)) assert.equal(existsSync(join(root, "cancel-observed")), true);
          if (["descendant", "ack-descendant"].includes(mode)) {
            const pid = JSON.parse(readFileSync(join(root, "descendant-pid"), "utf8"));
            assert.throws(() => process.kill(pid, 0), "contained descendant must exit before replacement");
          }
          const manual = JSON.parse(readFileSync(join(root, "manual-started"), "utf8"));
          if (config.previewOnly) assert.ok(Object.values(manual.capabilities).every((flag) => flag === false));
          let retiredQueueId;
          if (mode.startsWith("manual-")) {
            const followup = await client.describe("v1:github:114", 115, role);
            const manualPrepared = await client.prepareRun(followup,
              mode === "manual-replace" ? "replace" : "next", "isolated scheduling context");
            assert.equal(manualPrepared.conflict.kind, "manual");
            assert.equal(manualPrepared.conflict.workId, accepted[0].dispatchId);
            const followupQueue = await client.confirmRun(manualPrepared);
            if (["manual-next-cancel", "manual-next-expiry", "manual-next-cancel-race"].includes(mode)) {
              retiredQueueId = followupQueue.queueId;
              if (mode === "manual-next-cancel-race") {
                mark("delay-revalidation");
                mark("manual-release");
                await until(() => existsSync(join(root, "revalidating")), "predecessor completion race barrier");
              }
              if (mode === "manual-next-expiry") {
                await until(() => events.some((e) => e.queueId === retiredQueueId && e.code === "schedule-expired"), "successor expiry");
              } else {
                assert.equal((await client.cancelQueued(retiredQueueId)).queueId, retiredQueueId);
              }
              if (mode !== "manual-next-cancel-race") {
                await until(() => events.some((e) => e.queueId === retiredQueueId && e.code === "predecessor-running"), "predecessor reservation restored");
                process.kill(manual.pid, 0);
                assert.equal(launchFiles().length, 1, "cancelling B must not restart automatic work while A lives");
                assert.equal(events.some((e) => e.queueId === retiredQueueId && e.state === "resumed"), false);
                mark("manual-release");
              }
              await until(() => terminal.some((e) => e.dispatchId === accepted[0].dispatchId), "predecessor completion");
              assert.equal(accepted.length, 1, "retired successor must not execute");
            } else {
              if (mode === "manual-next") mark("manual-release");
              await until(() => accepted.length === 2, "second manual acceptance");
              assert.equal(accepted[1].queueId, followupQueue.queueId);
              assert.equal(accepted[1].pullRequestId, 115);
              mark("manual-release");
              await until(() => terminal.some((e) => e.dispatchId === accepted[1].dispatchId), "second manual completion");
            }
          } else {
            mark("manual-release");
            await until(() => terminal.some((e) => e.dispatchId === accepted[0].dispatchId), "manual completion");
          }
          if (mode === "auto-resume-fail") {
            await expectAutomaticFailure("automatic-startup-failed");
            assert.ok(events.some((e) => e.queueId === queued.queueId && e.state === "blocked" && e.code === "automatic-startup-failed"));
            assert.equal(launchFiles().length, 1, "a failed restart cannot be silently retried");
          } else {
            if (mode === "auto-resume-wait") {
              await until(() => existsSync(join(root, "resume-starting")), "automatic initialization barrier");
              assert.equal(events.some((e) => e.state === "resumed"), false, "process creation is not startup acknowledgement");
              mark("resume-allow");
            }
            await until(() => events.some((e) => e.state === "resumed" && (!retiredQueueId || e.queueId === retiredQueueId)), "automatic resumption");
            await until(() => launchFiles().length === 2, "original policy restarted");
            const specs = launchFiles().map((file) => JSON.parse(readFileSync(join(root, file), "utf8")));
            const withoutPid = ({ pid, ...rest }) => rest;
            assert.deepEqual(withoutPid(specs[0]), withoutPid(specs[1]));
          }
        }
      }
    }
  }
  writeFileSync(join(root, "verified.json"), JSON.stringify({ mode, role, states: events.map((e) => e.state) }));
} finally {
  await client.shutdown();
}
