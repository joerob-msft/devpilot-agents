import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { FileDismissalStorage } from "../src/dismissals.js";
import { parseAgentEvent } from "../src/domain.js";
import { OperationsReducer, STALE_AFTER_MS } from "../src/reducer.js";

const BASE = Date.now() - 60_000;
const NOW = BASE + STALE_AFTER_MS + 1_000;
function event(sequence = 1, type = "agent.started", time = BASE, id = "old") {
  return parseAgentEvent({
    schemaVersion: 2, agent: "reviewer", instanceId: id, processId: 42,
    sequence, eventType: type, timestamp: new Date(time).toISOString(), data: {},
  });
}

test("dismissals survive new reducers and log replay without modifying logs, state, or leases", async () => {
  const root = await mkdtemp(join(tmpdir(), "devpilot-dismissals-"));
  const storage = new FileDismissalStorage(join(root, "display"));
  try {
    const paths = ["events.jsonl", "state.v2.json", "state.v2.lock"].map((name) => join(root, name));
    for (const path of paths) await writeFile(path, JSON.stringify(event()));
    const first = new OperationsReducer();
    first.apply(event(), paths[0]);
    const record = first.dismissalFor("reviewer:old", NOW)!;
    assert.ok(record);
    await storage.save(record);
    assert.equal(first.dismissInstance(record, NOW), true);
    assert.equal(first.list(NOW, undefined, "current").length, 0);
    assert.ok(first.get(record.key), "dismissal does not delete reducer data");

    const second = new OperationsReducer(await new FileDismissalStorage(join(root, "display")).load());
    second.apply(event(), paths[0]);
    assert.equal(second.list(NOW, undefined, "current").length, 0);
    assert.equal(second.list(NOW, undefined, "live").length, 0);
    second.apply(event(2, "agent.heartbeat", NOW), paths[0]);
    assert.equal(second.list(NOW, undefined, "live").length, 1);
    assert.equal(second.list(NOW + 60_000, undefined, "current").length, 1,
      "new activity invalidates a dismissal rather than temporarily ignoring it");
    const third = new OperationsReducer(await storage.load());
    third.apply(event());
    third.apply(event(2, "agent.heartbeat", NOW));
    assert.equal(third.list(NOW + 60_000, undefined, "current").length, 1);
    for (const path of paths) assert.equal(await readFile(path, "utf8"), JSON.stringify(event()));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("finished rows stay in History; live waiting, failed and blocked agents cannot be dismissed", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event());
  reducer.apply(event(2, "agent.stopped"));
  const record = reducer.dismissalFor("reviewer:old", NOW)!;
  assert.equal(reducer.dismissInstance(record, NOW), true);
  assert.equal(reducer.list(NOW, undefined, "current").length, 0);
  assert.equal(reducer.list(NOW, undefined, "history").length, 1);
  assert.equal(reducer.restoreDismissedInstances(), 1);
  assert.equal(reducer.list(NOW, undefined, "current").length, 1);
  for (const type of ["agent.waiting", "cycle.failed", "delivery.blocked"]) {
    reducer.apply(event(1, "agent.started", NOW, type));
    reducer.apply(event(2, type, NOW, type));
    assert.equal(reducer.dismissalFor(`reviewer:${type}`, NOW), null);
    assert.ok(reducer.dismissalFor(`reviewer:${type}`, NOW + STALE_AFTER_MS + 1));
  }
});

test("new activity during persistence prevents an obsolete dismissal from hiding the agent", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event());
  const record = reducer.dismissalFor("reviewer:old", NOW)!;
  reducer.apply(event(2, "agent.heartbeat", NOW));
  assert.equal(reducer.dismissInstance(record, NOW), false);
  assert.equal(reducer.list(NOW, undefined, "live").length, 1);
});

test("independent dashboards preserve each other's dismissals; restore removes only display records", async () => {
  const root = await mkdtemp(join(tmpdir(), "devpilot-dismissals-"));
  try {
    const first = new FileDismissalStorage(root);
    const second = new FileDismissalStorage(root);
    await first.save({ key: "reviewer:one", throughSequence: 1 });
    await second.save({ key: "review-handler:two", throughSequence: 2 });
    await first.save({ key: "reviewer:one", throughSequence: 3 });
    assert.deepEqual((await second.load()).sort((a, b) => a.key.localeCompare(b.key)), [
      { key: "review-handler:two", throughSequence: 2 }, { key: "reviewer:one", throughSequence: 3 },
    ]);
    await writeFile(join(root, "unrelated.jsonl"), "keep");
    assert.equal(await second.restoreAll(), 2);
    assert.deepEqual(await first.load(), []);
    assert.deepEqual(await readdir(root), ["unrelated.jsonl"]);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("missing storage is normal, but corrupt, mismatched and inaccessible storage reports errors", async () => {
  const root = await mkdtemp(join(tmpdir(), "devpilot-dismissals-"));
  try {
    assert.deepEqual(await new FileDismissalStorage(join(root, "missing")).load(), []);
    const storage = new FileDismissalStorage(root);
    await storage.save({ key: "reviewer:one", throughSequence: 1 });
    const path = join(root, (await readdir(root))[0]!);
    await writeFile(path, "{");
    await assert.rejects(storage.load());
    await writeFile(path, JSON.stringify({ key: "reviewer:other", throughSequence: 1 }));
    await assert.rejects(storage.load(), /Invalid dashboard dismissal record/);
    await writeFile(path, "x".repeat(4097));
    await assert.rejects(storage.load(), /Oversized dashboard dismissal record/);
    assert.equal(await storage.restoreAll(), 1, "corruption is recoverable without deleting unrelated data");
    await assert.rejects(storage.save({ key: "../../elsewhere", throughSequence: 1 }));
    await assert.rejects(storage.save({ key: "reviewer:one", throughSequence: -1 }));
    const notDirectory = join(root, "file");
    await writeFile(notDirectory, "keep");
    await assert.rejects(new FileDismissalStorage(notDirectory).load());
    await assert.rejects(new FileDismissalStorage(notDirectory).save({ key: "reviewer:one", throughSequence: 1 }));
    assert.equal(await readFile(notDirectory, "utf8"), "keep");
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("a lagging dashboard cannot replace a newer dismissal watermark with an older one", async () => {
  const root = await mkdtemp(join(tmpdir(), "devpilot-dismissals-"));
  try {
    const first = new FileDismissalStorage(root);
    const lagging = new FileDismissalStorage(root);
    await first.save({ key: "reviewer:old", throughSequence: 3 });
    await lagging.save({ key: "reviewer:old", throughSequence: 1 });
    assert.deepEqual(await first.load(), [{ key: "reviewer:old", throughSequence: 3 }]);
    const restarted = new OperationsReducer(await first.load());
    restarted.apply(event(1));
    restarted.apply(event(2, "agent.heartbeat"));
    restarted.apply(event(3, "agent.stopped"));
    assert.equal(restarted.list(NOW, undefined, "current").length, 0);
    restarted.apply(event(4, "agent.heartbeat", NOW));
    assert.equal(restarted.list(NOW, undefined, "current").length, 1);
    assert.equal(await first.restoreAll(), 1);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("dismissal accepts the full instance-ID bound and keeps same-ID agent roles independent", async () => {
  const root = await mkdtemp(join(tmpdir(), "devpilot-dismissals-"));
  try {
    const storage = new FileDismissalStorage(root);
    const id = "x".repeat(512);
    await storage.save({ key: `reviewer:${id}`, throughSequence: 1 });
    await storage.save({ key: `review-handler:${id}`, throughSequence: 2 });
    assert.equal((await storage.load()).length, 2);
    assert.equal(await storage.restoreAll(), 2);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("replaying phase events cannot undo a dismissal without a newer heartbeat", () => {
  const record = { key: "reviewer:old", throughSequence: 2 };
  const reducer = new OperationsReducer([record]);
  reducer.apply(event());
  reducer.apply(event(2, "agent.heartbeat"));
  reducer.apply(event(3, "phase.changed"));
  assert.equal(reducer.list(NOW, undefined, "current").length, 0);
  reducer.apply(event(4, "agent.started", NOW));
  assert.equal(reducer.list(NOW, undefined, "live").length, 1);
});
