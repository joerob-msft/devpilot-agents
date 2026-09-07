import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent } from "../src/domain.js";
import type { DispatchTerminal } from "../src/dispatch.js";
import { manualProgress } from "../src/manual-progress.js";
import { OperationsReducer } from "../src/reducer.js";

const started = Date.now();
const dispatchId = "44444444-4444-4444-8444-444444444444";
const repositoryIdentity = {
  schemaVersion: 1, provider: "GitHub", repositoryId: "101", organization: "configured", project: "",
  repositoryName: "repo", slug: "configured/repo", key: "v1:github:101",
  verifiedAtUtc: new Date(started).toISOString(), verified: true, dispatchEligible: true,
};
function event(sequence: number, eventType: string, data = {}, overrides = {}) {
  return parseAgentEvent({
    schemaVersion: 3, agent: "reviewer", instanceId: "manual", processId: 42,
    timestamp: new Date(started + sequence).toISOString(), sequence, eventType, data,
    pullRequestId: 104, repositoryIdentity,
    dispatch: { schemaVersion: 1, dispatchId, ownership: "tui", forceAnalysis: true },
    ...overrides,
  });
}
const completed: DispatchTerminal = {
  schemaVersion: 1, operation: "completed", requestId: "terminal", dispatchId, exitCode: 0,
};

test("manual progress distinguishes acceptance, delayed telemetry, cancellation and transport-only completion", () => {
  const progress = (now: number, terminal: DispatchTerminal | null = null, error = "", cancelling = false) =>
    manualProgress(undefined, terminal, started, terminal ? started + 1000 : null, now, cancelling, error);
  assert.equal(progress(started).headline, "STARTED / RUNNING");
  assert.match(progress(started).detail, /no agent events/);
  assert.equal(progress(started + 30_001).headline, "STARTED / PROGRESS UNKNOWN");
  assert.equal(progress(started, null, "", true).headline, "CANCELLING...");
  assert.equal(progress(started, null, "broker gone").headline, "STATUS UNKNOWN");
  assert.equal(progress(started, completed).headline, "FINISHED");
  assert.match(progress(started, completed).detail, /outcome was not reported/);
  assert.equal(progress(started + 99_000, completed).elapsed, "1s");
  assert.equal(progress(started, { ...completed, exitCode: 1 }).headline, "FAILED");
  assert.equal(progress(started, { ...completed, operation: "cancelled", result: "cancelled-forced" }).headline, "CANCELLED");
});

test("exact dispatch progress survives filters, forgotten history, timeline eviction and heartbeat-only startup", () => {
  const reducer = new OperationsReducer();
  const get = () => reducer.getDispatch(dispatchId, repositoryIdentity.key, "reviewer", 104, 42, started + 1_000);
  reducer.apply(event(1, "agent.heartbeat", {}, { pullRequestId: 0 }));
  assert.ok(get(), "PR context need not be set at initial heartbeat");
  reducer.apply(event(2, "phase.changed", { phase: "manual model review" }));
  reducer.apply(event(1, "work.completed", { result: "failed" }, { instanceId: "automatic", dispatch: null }));
  assert.equal(get()?.phase, "manual model review");
  for (const overrides of [
    { dispatch: { schemaVersion: 1, dispatchId: "55555555-5555-4555-8555-555555555555", ownership: "tui", forceAnalysis: true } },
    { agent: "review-handler" }, { processId: 99 }, { pullRequestId: 105 },
    { repositoryIdentity: { ...repositoryIdentity, key: "v1:github:202", repositoryId: "202" } },
  ]) {
    const other = new OperationsReducer();
    other.apply(event(1, "agent.started", {}, overrides));
    assert.equal(other.getDispatch(dispatchId, repositoryIdentity.key, "reviewer", 104, 42), undefined);
  }
  for (let sequence = 3; sequence <= 510; sequence++) reducer.apply(event(sequence, "phase.changed", { phase: "reviewing" }));
  reducer.apply(event(511, "agent.stopped"));
  reducer.forgetHistorical("reviewer:manual");
  assert.equal(reducer.list(started + 1_000, "review-handler", "live").length, 0);
  assert.ok(get(), "manual progress is never filtered out");
});

test("matching work outcome and lifecycle take precedence over exit zero, never over cancellation", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event(1, "agent.started"));
  reducer.apply(event(2, "phase.changed", { phase: "running model review" }));
  const progress = (terminal: DispatchTerminal | null = null, now = started + 1_000) =>
    manualProgress(reducer.get("reviewer:manual", now), terminal, started, null, now, false, "");
  assert.match(progress().detail, /running model review/);
  assert.equal(progress(null, started + 21_000).headline, "STARTED / PROGRESS UNKNOWN");
  reducer.apply(event(3, "work.completed", { result: "reviewed", summary: "Review summary" }));
  assert.equal(progress().headline, "STARTED / RUNNING", "work completion does not prove child exit");
  reducer.apply(event(4, "delivery.blocked", { reason: "Comments unavailable" }));
  assert.equal(progress(completed).headline, "BLOCKED");
  assert.match(progress(completed).detail, /Comments unavailable/);
  reducer.apply(event(5, "work.completed", { result: "failed", reason: "Model failed", summary: "Failure summary" }));
  assert.equal(progress(completed).headline, "FAILED");
  assert.equal(progress(completed).latest, "Failure summary");
  assert.equal(progress({ ...completed, operation: "cancelled" }).headline, "CANCELLED");
  assert.equal(reducer.apply(event(2, "work.completed", { result: "reviewed" })), false);
  assert.equal(progress(completed).headline, "FAILED", "stale sequences cannot overwrite outcomes");
  reducer.apply(event(6, "work.completed", { result: "reviewed", summary: "Finished review" }));
  reducer.apply(event(7, "agent.stopped"));
  assert.equal(progress().headline, "FINISHED");
});
