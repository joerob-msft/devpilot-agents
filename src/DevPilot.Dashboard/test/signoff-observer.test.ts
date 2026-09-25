import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { AGENTS, parseAgentEvent } from "../src/domain.js";
import { DELEGABLE_CAPABILITY_BY_ROLE } from "../src/dispatch.js";
import { OperationsReducer } from "../src/reducer.js";
import { simpleInstanceRow, simpleRole } from "../src/simple-view.js";
import { discoverEventLogs } from "../src/tailer.js";
import { createDashboardLifecycle } from "../src/lifecycle.js";

function event(sequence: number, eventType: string, data: Record<string, unknown> = {}, agent = "signoff-observer") {
  return parseAgentEvent({
    schemaVersion: 2, agent, instanceId: "study-worker", processId: 123,
    timestamp: new Date(Date.parse("2026-01-01T12:00:00Z") + sequence * 1000).toISOString(),
    sequence, eventType, level: "info", cycleNumber: 1, pullRequestId: 0,
    sourceCommit: "", message: "", data,
  });
}

const progress = {
  studyId: "public-study", mode: "collection-only", deadline: "2026-01-08T12:00:00Z",
  families: 25, admissions: 0, eligibleAgreement: 0, reportPath: "private-report.md",
  finalRecommendation: "NEEDS_HUMAN_REVIEW", diagnostic: "APPROVE",
  eligibilityReasons: ["POLICY_MISSING"], collectionStatus: "complete", lastFamilyId: "fixture:1",
};

test("observer is a third read-only event role without delegable capabilities", () => {
  assert.deepEqual(AGENTS, ["reviewer", "review-handler", "signoff-observer"]);
  assert.equal(DELEGABLE_CAPABILITY_BY_ROLE["signoff-observer"], null);
  assert.equal(DELEGABLE_CAPABILITY_BY_ROLE.reviewer, "EnableApprovalVote");
  assert.equal(simpleRole("signoff-observer"), "Sign-off Observer");
});

test("observer progress is reduced and filtered without widening authority", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event(1, "agent.started"));
  reducer.apply(event(2, "observer.updated", { ...progress, capabilities: ["EnableApprovalVote"] }));
  reducer.apply(event(3, "agent.started", {}, "reviewer"));
  const state = reducer.get("signoff-observer:study-worker")!;
  assert.equal(state.observer?.families, 25);
  assert.equal(state.observer?.admissions, 0);
  assert.equal(state.writes, "none");
  assert.equal(state.vote, "off");
  assert.deepEqual(state.capabilities, []);
  assert.equal(reducer.list(Date.now(), "signoff-observer").length, 1);
  assert.equal(reducer.list(Date.now(), "reviewer").length, 1);
});

test("simple observer details keep diagnostic distinct from policy and show denominators", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event(1, "agent.started"));
  reducer.apply(event(2, "observer.updated", progress));
  const row = simpleInstanceRow(reducer.get("signoff-observer:study-worker")!);
  const details = row.details.join("\n");
  assert.match(details, /Last snapshot final policy \(not study-wide\): NEEDS_HUMAN_REVIEW/);
  assert.match(details, /Model-only diagnostic \(not policy approval\): APPROVE/);
  assert.match(details, /Families: 25; evaluations admitted: 0; eligible human comparisons: 0/);
  assert.match(details, /POLICY_MISSING/);
  assert.match(details, /No approval authorization/);
});

test("incomplete capture stays visibly actionable even after worker stops", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event(1, "agent.started"));
  reducer.apply(event(2, "observer.updated", { ...progress, collectionStatus: "incomplete" }));
  reducer.apply(event(3, "agent.stopped"));
  const row = simpleInstanceRow(reducer.get("signoff-observer:study-worker")!);
  assert.equal(row.attention, true);
  assert.match(row.details.join("\n"), /Capture incomplete/);
});

test("observer updates cannot change a legacy role's state", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event(1, "agent.started", {}, "review-handler"));
  reducer.apply(event(2, "observer.updated", progress, "review-handler"));
  assert.equal(reducer.get("review-handler:study-worker")?.observer, undefined);
});

test("tailer discovers headless and alongside observer event directories", async () => {
  const root = await mkdtemp(join(tmpdir(), "signoff-dashboard-"));
  try {
    const headless = join(root, "logs", "events", "signoff-observer");
    const alongside = join(root, "signoff-observer", "logs", "events", "signoff-observer");
    await mkdir(headless, { recursive: true });
    await mkdir(alongside, { recursive: true });
    const files = [join(headless, "one.jsonl"), join(alongside, "two.jsonl")];
    await Promise.all(files.map((file) => writeFile(file, JSON.stringify(event(1, "agent.started")) + "\n")));
    const discovered = await discoverEventLogs([root], []);
    for (const file of files) assert.ok(discovered.includes(file));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("closing an attach-only dashboard leaves its separately owned worker responsive", async () => {
  const worker = spawn(process.execPath, ["-e", "setInterval(() => process.stdout.write('alive\\n'), 50)"],
    { stdio: ["ignore", "pipe", "ignore"] });
  try {
    await once(worker.stdout!, "data");
    let stopped = 0;
    const lifecycle = createDashboardLifecycle({ stop: async () => { stopped++; } });
    lifecycle.onRendererDestroy();
    await lifecycle.shutdownTailer();
    await lifecycle.shutdownBroker();
    await once(worker.stdout!, "data");
    assert.equal(stopped, 1);
    assert.equal(worker.exitCode, null);
    assert.equal(worker.killed, false);
  } finally {
    const closed = once(worker, "close");
    worker.kill();
    await closed;
  }
});
