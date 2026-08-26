import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent, type AgentEvent } from "../src/domain.js";
import {
  DIAGNOSTIC_LIMIT,
  OperationsReducer,
  STALE_AFTER_MS,
  TIMELINE_LIMIT,
  liveElapsedMilliseconds,
} from "../src/reducer.js";

const BASE_TIME = Date.parse("2026-08-25T12:00:00.000Z");

function event(
  instanceId: string,
  sequence: number,
  eventType: string,
  overrides: Partial<Record<string, unknown>> = {},
): AgentEvent {
  return parseAgentEvent({
    schemaVersion: 2,
    agent: "reviewer",
    instanceId,
    processId: 100,
    timestamp: new Date(BASE_TIME + sequence * 100).toISOString(),
    sequence,
    eventType,
    level: "info",
    cycleNumber: 1,
    pullRequestId: 0,
    sourceCommit: "",
    data: {},
    message: "",
    ...overrides,
  });
}

test("reducer tracks scope, work state, completion, and live elapsed", () => {
  const reducer = new OperationsReducer();
  reducer.apply(
    event("a", 1, "agent.started", {
      data: {
        organization: "org",
        project: "project",
        repository: "repo",
        target: "main",
        operator: "operator",
        capabilities: ["comments"],
      },
    }),
  );
  reducer.apply(event("a", 2, "candidate.selected", { pullRequestId: 42, data: { title: "A bounded title" } }));
  reducer.apply(
    event("a", 3, "phase.changed", {
      pullRequestId: 42,
      data: { phase: "running the model", elapsedMilliseconds: 1_500 },
    }),
  );
  const state = reducer.get("reviewer:a", BASE_TIME + 1_000);
  assert.ok(state);
  assert.equal(state.repository, "repo");
  assert.equal(state.pullRequestId, 42);
  assert.equal(state.pullRequestTitle, "A bounded title");
  assert.equal(state.phase, "running the model");
  assert.equal(liveElapsedMilliseconds(state, BASE_TIME + 1_300), 2_500);

  reducer.apply(
    event("a", 4, "work.completed", {
      pullRequestId: 42,
      data: { result: "reviewed", delivered: "preview", critical: 1, important: 2, suggestion: 3 },
    }),
  );
  assert.deepEqual(reducer.get("reviewer:a", BASE_TIME + 500)?.completion?.findings, {
    critical: 1,
    important: 2,
    suggestion: 3,
  });
});

test("attention ordering is failed, blocked, running, waiting, completed", () => {
  const reducer = new OperationsReducer();
  for (const id of ["failed", "blocked", "running", "waiting", "completed"]) {
    reducer.apply(event(id, 1, "agent.started"));
  }
  reducer.apply(event("failed", 2, "cycle.failed", { level: "error", data: { reason: "boom" } }));
  reducer.apply(
    event("blocked", 2, "delivery.blocked", {
      level: "warning",
      data: { reason: "delivery pending", retryable: true, outstanding: ["comments"] },
    }),
  );
  reducer.apply(event("waiting", 2, "agent.waiting", { data: { kind: "cycle", delayMilliseconds: 5_000 } }));
  reducer.apply(event("completed", 2, "agent.stopped"));
  assert.deepEqual(
    reducer.list(BASE_TIME + 1_000).map((item) => item.instanceId),
    ["failed", "blocked", "running", "waiting", "completed"],
  );
});

test("duplicates are ignored and sequence gaps are surfaced", () => {
  const reducer = new OperationsReducer();
  assert.equal(reducer.apply(event("gap", 1, "agent.started"), "events.jsonl"), true);
  assert.equal(reducer.apply(event("gap", 1, "agent.started"), "events.jsonl"), false);
  assert.equal(reducer.apply(event("gap", 4, "phase.changed"), "events.jsonl"), true);
  const state = reducer.get("reviewer:gap", BASE_TIME + 500);
  assert.equal(state?.duplicateCount, 1);
  assert.equal(state?.gapCount, 2);
  assert.match(state?.sourceDiagnostics[0]?.message ?? "", /missing 2/);
});

test("diagnostics that precede the first valid source event are retained", () => {
  const reducer = new OperationsReducer();
  reducer.addSourceDiagnostic({
    source: "late.jsonl",
    kind: "malformed",
    message: "first line was malformed",
    timestampMs: BASE_TIME,
  });
  reducer.apply(event("late", 1, "agent.started"), "late.jsonl");
  assert.equal(reducer.get("reviewer:late", BASE_TIME + 100)?.sourceDiagnostics.length, 1);
});

test("timeline and source diagnostics remain bounded", () => {
  const reducer = new OperationsReducer();
  for (let sequence = 1; sequence <= TIMELINE_LIMIT + 25; sequence++) {
    reducer.apply(event("bounded", sequence, "phase.changed"), "events.jsonl");
  }
  for (let index = 0; index < DIAGNOSTIC_LIMIT + 10; index++) {
    reducer.addSourceDiagnostic({
      source: "events.jsonl",
      kind: "malformed",
      message: `bad line ${index} ${"x".repeat(500)}`,
      timestampMs: BASE_TIME + index,
    });
  }
  const state = reducer.get("reviewer:bounded", BASE_TIME + 60_000);
  assert.equal(state?.timeline.length, TIMELINE_LIMIT);
  assert.equal(state?.sourceDiagnostics.length, DIAGNOSTIC_LIMIT);
  assert.ok((state?.sourceDiagnostics.at(-1)?.message.length ?? 0) <= 240);
});

test("heartbeat age marks active instances stale", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("stale", 1, "agent.started"));
  assert.equal(reducer.get("reviewer:stale", BASE_TIME + 500)?.status, "running");
  assert.equal(reducer.get("reviewer:stale", BASE_TIME + STALE_AFTER_MS + 200)?.status, "stale");
  reducer.apply(event("stale", 2, "agent.heartbeat"));
  assert.equal(reducer.get("reviewer:stale", BASE_TIME + STALE_AFTER_MS)?.status, "running");
});

test("heartbeats update liveness without flooding the visible timeline", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("quiet", 1, "agent.started"));
  for (let sequence = 2; sequence <= 20; sequence++) {
    reducer.apply(event("quiet", sequence, "agent.heartbeat"));
  }
  assert.equal(reducer.get("reviewer:quiet", BASE_TIME + 2_100)?.timeline.length, 1);
  assert.equal(reducer.get("reviewer:quiet", BASE_TIME + 2_100)?.lastSequence, 20);
});

test("source diagnostics remain visible before any valid instance event", () => {
  const reducer = new OperationsReducer();
  const diagnostic = {
    source: "broken.jsonl",
    kind: "malformed" as const,
    message: "invalid JSON",
    timestampMs: BASE_TIME,
  };
  reducer.addSourceDiagnostic(diagnostic);
  reducer.addSourceDiagnostic(diagnostic);
  assert.deepEqual(reducer.globalDiagnostics(), [diagnostic]);
});
