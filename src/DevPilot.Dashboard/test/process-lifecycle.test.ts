import assert from "node:assert/strict";
import test from "node:test";
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { parseAgentEvent, type AgentEvent } from "../src/domain.js";
import { OperationsReducer, STALE_AFTER_MS } from "../src/reducer.js";
import { observeProcess, type ProcessPresence } from "../src/process-observer.js";
import { PullRequestHistoryProjection } from "../src/history.js";
import { EventTailer } from "../src/tailer.js";

const BASE = Date.parse("2026-09-05T12:00:00Z");
const NOW = BASE + STALE_AFTER_MS + 1_000;
const SOURCE = join(process.cwd(), "local.stdout.jsonl");
function applyLocal(reducer: OperationsReducer, value: AgentEvent, source = SOURCE): void {
  reducer.registerLocalStream({ eventLogPath: source, processId: value.processId, role: value.agent });
  reducer.apply(value, source);
}
function event(instanceId = "old", sequence = 1, eventType = "agent.started", timestampMs = BASE) {
  return parseAgentEvent({
    schemaVersion: 3, agent: "reviewer", instanceId, processId: 42, sequence, eventType,
    timestamp: new Date(timestampMs).toISOString(), pullRequestId: 104,
    repositoryIdentity: {
      schemaVersion: 1, provider: "GitHub", repositoryId: "101", organization: "sample",
      project: "", repositoryName: "repo", slug: "sample/repo", key: "v1:github:101",
      verifiedAtUtc: new Date(BASE).toISOString(), verified: true, dispatchEligible: true,
    },
    data: { repository: "repo", title: "Preserved PR", author: "Ada", result: "reviewed" },
  });
}

test("copied, shared and remote streams never acquire local origin from paths, host claims, or a matching present PID", async () => {
  for (const processId of [42, process.pid, 2_147_483_647]) {
    const reducer = new OperationsReducer();
    reducer.registerLocalStream({ eventLogPath: SOURCE, processId, role: "reviewer" });
    const copy = { ...event(), processId, data: { ...event().data, hostname: "localhost", processOrigin: "local" } };
    const copiedPath = join(process.cwd(), "copied.jsonl");
    reducer.apply(copy, copiedPath);
    let probes = 0;
    await reducer.observeProcesses(async () => { probes++; return "present"; }, NOW);
    await reducer.observeProcesses(async () => { probes++; return "absent"; }, NOW + 5_001);
    assert.equal(probes, 0);
    assert.equal(reducer.get("reviewer:old", NOW)?.processOrigin, "unknown");
    assert.equal(reducer.list(NOW, undefined, "current")[0]?.status, "stale");
    assert.equal(reducer.list(NOW, undefined, "history").length, 0);
    reducer.apply(copy, SOURCE); // The same event is now actually observed via the owned capture.
    assert.equal(reducer.get("reviewer:old", NOW)?.processOrigin, "local");
    await reducer.observeProcesses(async () => "absent", NOW + 10_002);
    assert.equal(reducer.list(NOW, undefined, "current").length, 0);
  }
});

test("trusted stream provenance is exact to PID, role, and accepted manual dispatch tuple", async () => {
  const dispatch = { dispatchId: "11111111-1111-4111-8111-111111111111", repositoryKey: "v1:github:101", pullRequestId: 104 };
  const manual = { ...event(), dispatch: { schemaVersion: 1 as const, dispatchId: dispatch.dispatchId, ownership: "tui" as const, forceAnalysis: true } };
  for (const overrides of [
    { processId: 43 }, { agent: "review-handler" as const }, { dispatch: null },
    { pullRequestId: 205 },
    { repositoryIdentity: { ...manual.repositoryIdentity!, key: "v1:github:202" } },
    { dispatch: { ...manual.dispatch, dispatchId: "22222222-2222-4222-8222-222222222222" } },
  ]) {
    const reducer = new OperationsReducer();
    reducer.registerLocalStream({ eventLogPath: SOURCE, processId: 42, role: "reviewer", dispatch });
    reducer.apply({ ...manual, ...overrides }, SOURCE);
    assert.equal(await reducer.observeProcesses(async () => "absent", NOW), false);
    assert.equal(reducer.list(NOW, undefined, "current").length, 1);
  }
  const reducer = new OperationsReducer();
  reducer.registerLocalStream({ eventLogPath: SOURCE, processId: 42, role: "reviewer", dispatch });
  reducer.apply({ ...manual, pullRequestId: 0 }, `${SOURCE}.1`);
  assert.equal(await reducer.observeProcesses(async () => "absent", NOW), true);
  assert.equal(reducer.list(NOW, undefined, "current").length, 0);
});

test("loading a locally present event file without launcher provenance cannot retire its PID", async () => {
  const root = await mkdtemp(join(process.cwd(), ".process-lifecycle-untrusted-"));
  const path = join(root, "logs", "events", "reviewer", "copied.jsonl");
  try {
    await mkdir(join(root, "logs", "events", "reviewer"), { recursive: true });
    await writeFile(path, `${JSON.stringify(event())}\n`);
    for (const explicit of [false, true]) {
      const reducer = new OperationsReducer();
      let probes = 0;
      const tailer = new EventTailer({
        stateDirectories: explicit ? [] : [root], eventLogPaths: explicit ? [path] : [],
        onEvent: (value, source) => { reducer.apply(value, source); }, onDiagnostic: () => {},
        onPoll: async () => { await reducer.observeProcesses(async () => { probes++; return "absent"; }, NOW); },
      });
      await tailer.poll();
      assert.equal(probes, 0);
      assert.equal(reducer.list(NOW, undefined, "current")[0]?.status, "stale");
      await tailer.stop();
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("late local acceptance correlates an already-read source/event pair without borrowing another source's tuple", async () => {
  const dispatch = { dispatchId: "11111111-1111-4111-8111-111111111111", repositoryKey: "v1:github:101", pullRequestId: 104 };
  const manual = { ...event(), dispatch: { schemaVersion: 1 as const, dispatchId: dispatch.dispatchId, ownership: "tui" as const, forceAnalysis: true } };
  for (const copiedLast of [false, true]) {
    const reducer = new OperationsReducer();
    reducer.apply(manual, SOURCE);
    if (copiedLast) reducer.apply(manual, join(process.cwd(), "copy.jsonl"));
    reducer.registerLocalStream({ eventLogPath: SOURCE, processId: 42, role: "reviewer", dispatch });
    assert.equal(await reducer.observeProcesses(async () => "absent", NOW), !copiedLast);
    assert.equal(reducer.list(NOW, undefined, "current").length, copiedLast ? 1 : 0);
  }
});

test("an instance's changed PID loses local provenance unless the producer vouches for that PID too", async () => {
  const reducer = new OperationsReducer();
  applyLocal(reducer, event());
  reducer.apply({ ...event("old", 2, "agent.heartbeat", BASE + 100), processId: 43 }, SOURCE);
  let probes = 0;
  await reducer.observeProcesses(async () => { probes++; return "absent"; }, NOW);
  assert.equal(probes, 0);
  assert.equal(reducer.list(NOW, undefined, "current")[0]?.processOrigin, "unknown");
  reducer.registerLocalStream({ eventLogPath: SOURCE, processId: 43, role: "reviewer" });
  assert.equal(await reducer.observeProcesses(async () => "absent", NOW + 5_001), true);
});

test("staleness, present/reused PIDs and unknown/denied observations never retire a run from Current", async () => {
  for (const presence of ["present", "unknown", "denied"] as const) {
    const reducer = new OperationsReducer();
    applyLocal(reducer, event("old"));
    applyLocal(reducer, event("different-instance-same-pid"));
    assert.equal(reducer.list(NOW, undefined, "current").length, 2);
    assert.equal(await reducer.observeProcesses(async () => {
      if (presence === "denied") throw Object.assign(new Error("access denied"), { code: "EPERM" });
      return presence;
    }, NOW), false);
    assert.equal(reducer.list(NOW, undefined, "current").length, 2);
    assert.ok(reducer.list(NOW, undefined, "current").every((state) => state.status === "stale"));
    assert.equal(reducer.list(NOW, undefined, "live").length, 0);
    assert.equal(reducer.list(NOW, undefined, "history").length, 0);
  }
});

test("definite absence archives interrupted work without synthesizing completion or history events", async () => {
  const reducer = new OperationsReducer();
  const history = new PullRequestHistoryProjection();
  const started = event();
  applyLocal(reducer, started);
  history.apply(started);
  const priorHistory = JSON.stringify(history.list());
  assert.equal(await reducer.observeProcesses(async () => "absent", NOW), true);
  assert.equal(reducer.list(NOW, undefined, "current").length, 0);
  assert.equal(reducer.list(NOW, undefined, "live").length, 0);
  const archived = reducer.list(NOW, undefined, "history")[0]!;
  assert.equal(archived.status, "exited");
  assert.equal(archived.lifecycle, "active", "raw agent lifecycle is not fabricated");
  assert.equal(archived.completion, null);
  assert.equal(archived.exitObservedMs, NOW);
  assert.equal(archived.pullRequestTitle, "", "agent.started does not invent candidate context");
  assert.deepEqual(archived.timeline, [started]);
  assert.deepEqual(archived.sources, [SOURCE]);
  assert.equal(JSON.stringify(history.list()), priorHistory);
  assert.equal(history.list()[0]?.title, "Preserved PR");
  assert.deepEqual(history.list()[0]?.outcomes, {});
  assert.equal(reducer.forgetHistorical(archived.key), true);
  assert.equal(reducer.restoreAllHistorical(), 1);
  assert.equal(reducer.list(NOW, undefined, "history").length, 1);
});

test("archiving preserves reported outcomes and the existing newest orderly outcome on Current", async () => {
  const reducer = new OperationsReducer();
  applyLocal(reducer, event("orderly", 1, "work.completed"));
  applyLocal(reducer, event("orderly", 2, "agent.stopped"));
  applyLocal(reducer, event("orphan", 1, "work.completed", BASE + 100));
  await reducer.observeProcesses(async () => "absent", NOW);
  assert.deepEqual(reducer.list(NOW, undefined, "current").map((state) => state.instanceId), ["orderly"]);
  const orphan = reducer.get("reviewer:orphan", NOW)!;
  assert.equal(orphan.status, "completed");
  assert.equal(orphan.completion?.result, "reviewed");
  assert.equal(reducer.list(NOW, undefined, "history").length, 2);
});

test("a process observation is invalidated by new sequence or PID, and late events restore archived state", async () => {
  for (const pidChanged of [false, true]) {
    const reducer = new OperationsReducer();
    applyLocal(reducer, event());
    let release!: (presence: ProcessPresence) => void;
    const pending = reducer.observeProcesses(() => new Promise((resolve) => { release = resolve; }), NOW);
    applyLocal(reducer, { ...event("old", 2, "agent.heartbeat", NOW), processId: pidChanged ? 43 : 42 });
    release("absent");
    assert.equal(await pending, false);
    assert.equal(reducer.get("reviewer:old", NOW)?.exitObservedMs, null);
    assert.equal(reducer.list(NOW, undefined, "live").length, 1);
    const later = NOW + STALE_AFTER_MS + 1_000;
    await reducer.observeProcesses(async () => "absent", later);
    assert.equal(reducer.list(later, undefined, "current").length, 0);
    applyLocal(reducer, event("old", 3, "agent.heartbeat", later));
    assert.equal(reducer.list(later, undefined, "current").length, 1);
  }
});

test("same PID across instances cannot transfer a current heartbeat or an old absence result", async () => {
  const reducer = new OperationsReducer();
  applyLocal(reducer, event("old"));
  let release!: (presence: ProcessPresence) => void;
  const pending = reducer.observeProcesses(() => new Promise((resolve) => { release = resolve; }), NOW);
  applyLocal(reducer, event("current", 1, "agent.started", NOW));
  release("absent");
  await pending;
  assert.equal(reducer.get("reviewer:old", NOW)?.status, "stale");
  assert.equal(reducer.get("reviewer:current", NOW)?.exitObservedMs, null);
  assert.deepEqual(reducer.list(NOW, undefined, "live").map((state) => state.instanceId), ["current"]);
  assert.equal(reducer.list(NOW, undefined, "current").length, 2);
});

test("recent events postpone probing even if a heartbeat is overdue; polls are bounded", async () => {
  const reducer = new OperationsReducer();
  applyLocal(reducer, event());
  applyLocal(reducer, event("old", 2, "phase.changed", NOW));
  let calls = 0;
  const observe = async () => { calls++; return "present" as const; };
  await reducer.observeProcesses(observe, NOW);
  assert.equal(calls, 0);
  await reducer.observeProcesses(observe, NOW + STALE_AFTER_MS + 1);
  await reducer.observeProcesses(observe, NOW + STALE_AFTER_MS + 2);
  assert.equal(calls, 1);
});

test("native observation only uses signal zero, treats ESRCH as absence, and rejects unsafe PID values", async (context) => {
  const calls: [number, unknown][] = [];
  let code = "";
  const mocked = context.mock.method(process, "kill", (pid: number, signal?: string | number) => {
    calls.push([pid, signal]);
    if (code) throw Object.assign(new Error(code), { code });
    return true;
  });
  try {
    assert.equal(await observeProcess(42), "present");
    for (const errorCode of ["EPERM", "EACCES", "EINVAL", "ENOSYS"]) {
      code = errorCode;
      assert.equal(await observeProcess(42), "unknown");
    }
    code = "ESRCH";
    assert.equal(await observeProcess(42), "absent");
    for (const pid of [0, -1, 1.5, NaN, Infinity, 2_147_483_648]) {
      assert.equal(await observeProcess(pid), "unknown");
    }
    assert.equal(calls.length, 6);
    assert.ok(calls.every(([pid, signal]) => pid === 42 && signal === 0));
  } finally { mocked.mock.restore(); }
  assert.equal(await observeProcess(process.pid), "present");
  assert.equal(await observeProcess(2_147_483_647), "absent");
});

test("tailer archives after ingestion and re-derives exits on reload without changing any log bytes", async () => {
  const root = await mkdtemp(join(process.cwd(), ".process-lifecycle-"));
  const path = join(root, "logs", "events", "reviewer", "old.jsonl");
  try {
    await mkdir(join(root, "logs", "events", "reviewer"), { recursive: true });
    const contents = `${JSON.stringify(event())}\n`;
    await writeFile(path, contents);
    for (let reload = 0; reload < 2; reload++) {
      const reducer = new OperationsReducer();
      reducer.registerLocalStream({ eventLogPath: path, processId: 42, role: "reviewer" });
      const history = new PullRequestHistoryProjection();
      let now = NOW;
      const tailer = new EventTailer({
        stateDirectories: [root], eventLogPaths: [],
        onEvent: (value, source) => { reducer.apply(value, source); history.apply(value); },
        onDiagnostic: () => assert.fail("unexpected source diagnostic"),
        onPoll: async () => { await reducer.observeProcesses(async () => "absent", now); },
      });

      await tailer.poll();
      assert.equal(reducer.list(NOW, undefined, "current").length, 0);
      assert.equal(reducer.list(NOW, undefined, "history").length, 1);
      assert.equal(history.list().length, 1);
      assert.equal(await readFile(path, "utf8"), contents);
      if (reload === 1) {
        now = NOW + 5_001;
        await appendFile(path, `${JSON.stringify(event("old", 2, "agent.heartbeat", now))}\n`);
        await tailer.poll();
        assert.equal(reducer.list(now, undefined, "current").length, 1);
      }
      await tailer.stop();
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
