import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent, type AgentEvent } from "../src/domain.js";
import {
  DIAGNOSTIC_LIMIT,
  OperationsReducer,
  STALE_AFTER_MS,
  TIMELINE_LIMIT,
  liveElapsedMilliseconds,
  totalElapsedMilliseconds,
  sessionNamespaceFromSource,
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

  test("PR context is additive across candidate, reviewer, and completion events", () => {
    const reducer = new OperationsReducer();
    reducer.apply(event("context", 1, "agent.started"));
    reducer.apply(event("context", 2, "candidate.selected", {
      pullRequestId: 94,
      data: {
        title: "Contextual operations",
        author: "Ada",
        url: "https://github.com/org/repo/pull/94",
        sourceBranch: "feature/context",
        targetBranch: "main",
        threadCount: 12,
        actionableThreadCount: 4,
        changedFileCount: 7,
      },
    }));
    reducer.apply(event("context", 3, "reviewer.started", {
      data: { title: "Updated contextual operations", sourceBranch: "feature/context-v2" },
    }));
    reducer.apply(event("context", 4, "work.completed", {
      data: {
        author: "Grace",
        result: "partial",
        reason: "comments unavailable",
        summary: "Preview generated",
        requested: "summary, comments",
        delivered: ["summary"],
        previewArtifact: "preview.md",
        nextScan: "30 seconds",
        elapsedMilliseconds: 9_000,
        critical: 1,
        important: 2,
        suggestion: 3,
        threadCount: 15,
        actionableThreadCount: 5,
        changedFileCount: 9,
      },
    }));
    reducer.apply(event("context", 5, "agent.stopped"));

    const state = reducer.get("reviewer:context", BASE_TIME + 2_000);
    assert.ok(state);
    assert.equal(state.pullRequestId, 94);
    assert.equal(state.pullRequestTitle, "Updated contextual operations");
    assert.equal(state.pullRequestAuthor, "Grace");
    assert.equal(state.pullRequestUrl, "https://github.com/org/repo/pull/94");
    assert.equal(state.sourceBranch, "feature/context-v2");
    assert.equal(state.targetBranch, "main");
    assert.equal(state.threadCount, 15);
    assert.equal(state.actionableThreadCount, 5);
    assert.equal(state.changedFileCount, 9);
    assert.deepEqual(state.completion, {
      result: "partial",
      requested: ["summary", "comments"],
      delivered: ["summary"],
      reason: "comments unavailable",
      findings: { critical: 1, important: 2, suggestion: 3 },
      summary: "Preview generated",
      previewArtifact: "preview.md",
      nextScan: "30 seconds",
      elapsedMilliseconds: 9_000,
      timestampMs: BASE_TIME + 400,
    });
    assert.equal(totalElapsedMilliseconds(state, BASE_TIME + 20_000), 9_000);
  });

  test("PR progress counts are non-negative bounded integers", () => {
    const reducer = new OperationsReducer();
    reducer.apply(event("counts", 1, "candidate.selected", {
      data: {
        threadCount: 1_000_001.9,
        actionableThreadCount: -4,
        changedFileCount: 12.8,
      },
    }));
    const state = reducer.get("reviewer:counts", BASE_TIME + 500);
    assert.equal(state?.threadCount, 1_000_000);
    assert.equal(state?.actionableThreadCount, 0);
    assert.equal(state?.changedFileCount, 12);
  });

  test("a new cycle resets current narrative but stopped runs retain their summary", () => {
    const reducer = new OperationsReducer();
    reducer.apply(event("run", 1, "agent.started"));
    reducer.apply(event("run", 2, "cycle.started"));
    reducer.apply(event("run", 3, "review.completed", {
      data: { result: "reviewed", summary: "first run", elapsedMilliseconds: 100 },
    }));
    reducer.apply(event("run", 4, "agent.stopped"));
    assert.equal(reducer.get("reviewer:run", BASE_TIME + 1_000)?.completion?.summary, "first run");

    reducer.apply(event("run", 5, "cycle.started"));
    const state = reducer.get("reviewer:run", BASE_TIME + 1_000);
    assert.equal(state?.completion, null);
    assert.equal(state?.candidateStory, "Scanning candidates");
    assert.equal(state?.currentRunStartedMs, BASE_TIME + 500);
  });

  test("active work sorts before older stopped failure records", () => {
    const reducer = new OperationsReducer();
    reducer.apply(event("historical", 1, "agent.started"));
    reducer.apply(event("historical", 2, "cycle.failed", { data: { reason: "old failure" } }));
    reducer.apply(event("historical", 3, "agent.stopped"));
    reducer.apply(event("active", 1, "agent.started"));
    assert.deepEqual(
      reducer.list(BASE_TIME + 1_000).map((item) => item.instanceId),
      ["active", "historical"],
    );
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

test("partially delivered completion preserves an earlier production-order block", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("partial", 1, "agent.started"));
  reducer.apply(event("partial", 2, "candidate.selected", {
    pullRequestId: 94,
    data: { title: "Partial delivery" },
  }));
  reducer.apply(event("partial", 3, "delivery.blocked", {
    level: "warning",
    data: {
      reason: "comments remain outstanding",
      outstanding: ["comments", "threads"],
      retryable: true,
      nextRetry: "next cycle",
    },
  }));
  reducer.apply(event("partial", 4, "work.completed", {
    data: {
      result: "partially delivered",
      reason: "summary delivered; comments unresolved",
      delivered: ["summary"],
    },
  }));
  reducer.apply(event("running-peer", 1, "agent.started"));

  const state = reducer.get("reviewer:partial", BASE_TIME + 1_000);
  assert.equal(state?.status, "blocked");
  assert.deepEqual(state?.blocked, {
    reason: "comments remain outstanding",
    outstanding: ["comments", "threads"],
    retryable: true,
    nextRetry: "next cycle",
    timestampMs: BASE_TIME + 300,
  });
  assert.equal(state?.retryable, true);
  assert.deepEqual(state?.outstanding, ["comments", "threads"]);
  assert.deepEqual(
    reducer.list(BASE_TIME + 1_000).map((item) => item.instanceId),
    ["partial", "running-peer"],
  );
});

test("successful terminal results clear retry state for both agents", () => {
  for (const result of ["handled", "passed", "previewed", "promoted", "reviewed"]) {
    const reducer = new OperationsReducer();
    reducer.apply(event(result, 1, "agent.started"));
    reducer.apply(event(result, 2, "delivery.retrying", {
      data: { outstanding: ["comments"] },
    }));
    reducer.apply(event(result, 3, "work.completed", { data: { result } }));

    const state = reducer.get(`reviewer:${result}`, BASE_TIME + 1_000);
    assert.equal(state?.retryable, false, result);
    assert.deepEqual(state?.outstanding, [], result);
  }
});

test("a zero-candidate second cycle cannot retain stale current-PR context", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("cycles", 1, "agent.started"));
  reducer.apply(event("cycles", 2, "cycle.started"));
  reducer.apply(event("cycles", 3, "candidate.selected", {
    pullRequestId: 94,
    sourceCommit: "abcdef123456",
    data: {
      title: "First cycle PR",
      author: "Ada",
      url: "https://github.com/org/repo/pull/94",
      sourceBranch: "feature/first",
      targetBranch: "main",
      threadCount: 12,
      actionableThreadCount: 4,
      changedFileCount: 7,
    },
  }));
  reducer.apply(event("cycles", 4, "cycle.started", { cycleNumber: 2 }));
  reducer.apply(event("cycles", 5, "candidates.enumerated", {
    cycleNumber: 2,
    data: { scanned: 0, selected: 0, skipped: {} },
  }));

  const state = reducer.get("reviewer:cycles", BASE_TIME + 1_000);
  assert.ok(state);
  assert.equal(state.pullRequestId, 0);
  assert.equal(state.pullRequestTitle, "");
  assert.equal(state.pullRequestAuthor, "");
  assert.equal(state.pullRequestUrl, "");
  assert.equal(state.sourceBranch, "");
  assert.equal(state.targetBranch, "");
  assert.equal(state.threadCount, 0);
  assert.equal(state.actionableThreadCount, 0);
  assert.equal(state.changedFileCount, 0);
  assert.equal(state.sourceCommit, "");
  assert.equal(state.candidateStory, "Scanned 0; none selected; skipped 0");
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

test("work.concurrent is instance-observable without becoming PR history", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("concurrent", 1, "work.concurrent", { data: { reason: "lease-contended" } }));
  const state = reducer.list()[0]!;
  assert.equal(state.blocked?.reason, "lease-contended");
  assert.equal(state.retryable, true);
  assert.equal(state.modelActivity, "Waiting for concurrent work");
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

test("view filters distinguish live, current-session, and retained history", () => {
  const reducer = new OperationsReducer();
  const source = String.raw`C:\watch\session-a\logs\events\reviewer\events.jsonl`;
  reducer.apply(event("live", 1, "agent.started"), source);
  reducer.apply(event("older-history", 1, "agent.started"), source);
  reducer.apply(event("older-history", 2, "work.completed", { data: { result: "reviewed" } }), source);
  reducer.apply(event("older-history", 3, "agent.stopped"), source);
  reducer.apply(event("newer-history", 1, "agent.started"), source);
  reducer.apply(event("newer-history", 4, "work.completed", { data: { result: "passed" } }), source);
  reducer.apply(event("newer-history", 5, "agent.stopped"), source);

  assert.deepEqual(reducer.list(BASE_TIME + 1_000, undefined, "live").map((item) => item.instanceId), ["live"]);
  assert.deepEqual(
    reducer.list(BASE_TIME + 1_000, undefined, "current").map((item) => item.instanceId),
    ["live", "newer-history"],
  );
  const history = reducer.list(BASE_TIME + 1_000, undefined, "history");
  assert.deepEqual(history.map((item) => item.instanceId), ["newer-history", "older-history"]);
  assert.equal(history[0]?.completion?.result, "passed");
  assert.equal(history[0]?.completion?.timestampMs, BASE_TIME + 400);
});

test("continuous completion followed by waiting remains live until the agent stops", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("continuous", 1, "agent.started"));
  reducer.apply(event("continuous", 2, "work.completed", { data: { result: "reviewed" } }));
  reducer.apply(event("continuous", 3, "agent.waiting", {
    data: { kind: "cycle", delayMilliseconds: 30_000 },
  }));

  assert.equal(reducer.get("reviewer:continuous", BASE_TIME + 500)?.status, "waiting");
  assert.deepEqual(reducer.list(BASE_TIME + 500, undefined, "live").map((item) => item.instanceId), ["continuous"]);
  assert.equal(reducer.list(BASE_TIME + 500, undefined, "history").length, 0);
  assert.equal(reducer.forgetHistorical("reviewer:continuous"), false);

  reducer.apply(event("continuous", 4, "agent.stopped"));
  assert.equal(reducer.list(BASE_TIME + 500, undefined, "live").length, 0);
  assert.deepEqual(reducer.list(BASE_TIME + 500, undefined, "history").map((item) => item.instanceId), ["continuous"]);
  assert.equal(reducer.forgetHistorical("reviewer:continuous"), true);
});

test("active failed, blocked, and stale instances are live rather than history", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("failed-active", 1, "agent.started"));
  reducer.apply(event("failed-active", 2, "cycle.failed", { data: { reason: "transient failure" } }));
  reducer.apply(event("blocked-active", 1, "agent.started"));
  reducer.apply(event("blocked-active", 2, "delivery.blocked", {
    data: { reason: "delivery pending", retryable: true },
  }));
  reducer.apply(event("stale-active", 1, "agent.started"));

  const now = BASE_TIME + STALE_AFTER_MS + 500;
  assert.deepEqual(
    reducer.list(now, undefined, "live").map((item) => `${item.instanceId}:${item.status}`),
    ["failed-active:failed", "blocked-active:blocked", "stale-active:stale"],
  );
  assert.equal(reducer.list(now, undefined, "history").length, 0);
  assert.equal(reducer.forgetHistorical("reviewer:failed-active"), false);
  assert.equal(reducer.forgetHistorical("reviewer:blocked-active"), false);
  assert.equal(reducer.forgetHistorical("reviewer:stale-active"), false);
});

test("instances group deterministically by agent and source-derived session namespace", () => {
  assert.equal(
    sessionNamespaceFromSource(String.raw`C:\watch\session-42\logs\events\reviewer\events.jsonl.2`, "reviewer"),
    "session-42",
  );
  assert.equal(
    sessionNamespaceFromSource(String.raw`C:\captures\named-events.jsonl`, "reviewer"),
    "captures",
  );
  assert.equal(
    sessionNamespaceFromSource(
      String.raw`C:\watch\watch-20260826\Reviewer\logs\events\reviewer\events.jsonl`,
      "reviewer",
    ),
    "watch-20260826",
  );
  assert.equal(
    sessionNamespaceFromSource(
      String.raw`C:\watch\watch-20260826\review_handler\logs\events\review-handler\events.jsonl`,
      "review-handler",
    ),
    "watch-20260826",
  );

  const reducer = new OperationsReducer();
  reducer.apply(event("z", 1, "agent.started"), String.raw`C:\watch\session-z\logs\events\reviewer\events.jsonl`);
  reducer.apply(event("a", 1, "agent.started"), String.raw`C:\watch\session-a\logs\events\reviewer\events.jsonl`);
  assert.deepEqual(
    reducer.list(BASE_TIME + 500).map((item) => `${item.sessionNamespace}:${item.instanceId}`),
    ["session-a:a", "session-z:z"],
  );
});

test("forget controls hide only bounded historical view state and never active state", () => {
  const reducer = new OperationsReducer();
  reducer.apply(event("live", 1, "agent.started"));
  reducer.apply(event("old-1", 1, "agent.started"));
  reducer.apply(event("old-1", 2, "agent.stopped"));
  reducer.apply(event("old-2", 1, "agent.started"));
  reducer.apply(event("old-2", 2, "work.completed", { data: { result: "passed" } }));
  reducer.apply(event("old-2", 3, "agent.stopped"));

  assert.equal(reducer.forgetHistorical("reviewer:live"), false);
  assert.equal(reducer.forgetHistorical("reviewer:old-1"), true);
  assert.deepEqual(reducer.list(BASE_TIME + 500, undefined, "history").map((item) => item.instanceId), ["old-2"]);
  assert.equal(reducer.get("reviewer:old-1")?.instanceId, "old-1");
  assert.equal(reducer.forgetAllHistorical(1), 1);
  assert.equal(reducer.list(BASE_TIME + 500, undefined, "history").length, 0);
  assert.equal(reducer.list(BASE_TIME + 500, undefined, "live").length, 1);
});

test("forget all history covers the full documented in-memory bound", () => {
  const reducer = new OperationsReducer();
  for (let index = 0; index < 201; index++) {
    const instanceId = `history-${index}`;
    reducer.apply(event(instanceId, 1, "agent.started"));
    reducer.apply(event(instanceId, 2, "agent.stopped"));
  }

  assert.equal(reducer.forgetAllHistorical(), 201);
  assert.equal(reducer.list(BASE_TIME + 500, undefined, "history").length, 0);
});
