import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent } from "../src/domain.js";
import { AgentHealthProjection } from "../src/health.js";
import { PullRequestHistoryProjection } from "../src/history.js";
import { OperationsReducer } from "../src/reducer.js";

let sequence = 0;
function event(eventType: string, data: Record<string, unknown>, minute: number, agent = "reviewer") {
  return parseAgentEvent({
    schemaVersion: 3, agent, instanceId: "watch-1", processId: 7, sequence: ++sequence,
    timestamp: new Date(Date.UTC(2026, 10, 18, 9, minute)).toISOString(), eventType, level: "info", cycleNumber: 1,
    pullRequestId: 42, sourceCommit: "a".repeat(40), data, message: "", repositoryIdentity: {
      schemaVersion: 1, provider: "GitHub", repositoryId: "123", organization: "contoso", project: "", repositoryName: "api",
      slug: "contoso/api", key: "v1:github:123", verifiedAtUtc: "2026-11-10T00:00:00Z", verified: true, dispatchEligible: true,
    },
  });
}

test("failed work.completed carries failure detail, log path and kind into completion and PR history", () => {
  const started = event("agent.started", {}, 0);
  const failed = event("work.completed", {
    result: "deferred", failureDetail: "Error: No supported model available",
    failureLogPath: "C:\\watch\\reviewer\\logs\\failed-cycles\\pr42-cycle1.txt", failureKind: "persistent", title: "Retry keys",
  }, 0);
  const reducer = new OperationsReducer();
  reducer.apply(started, "events.jsonl");
  reducer.apply(failed, "events.jsonl");
  const completion = reducer.list(failed.timestampMs)[0]!.completion!;
  assert.equal(completion.failureDetail, "Error: No supported model available");
  assert.equal(completion.failureLogPath, "C:\\watch\\reviewer\\logs\\failed-cycles\\pr42-cycle1.txt");
  assert.equal(completion.failureKind, "persistent");

  const history = new PullRequestHistoryProjection();
  history.apply(failed);
  const outcome = history.list()[0]!.outcomes.reviewer!;
  assert.equal(outcome.failureDetail, "Error: No supported model available");
  assert.equal(outcome.failureKind, "persistent");

  const unknownKind = new OperationsReducer();
  unknownKind.apply(event("work.completed", { result: "failed", failureKind: "bogus" }, 1), "events.jsonl");
  assert.equal(unknownKind.list(Date.now())[0]!.completion!.failureKind, undefined);
});

test("health falls back to consecutive failed/deferred work.completed and prefers agent.health when present", () => {
  const health = new AgentHealthProjection();
  assert.equal(health.health("reviewer").source, "none");
  health.apply(event("work.completed", { result: "reviewed" }, 0), "s");
  health.apply(event("work.completed", { result: "deferred", failureDetail: "Error: A" }, 1), "s");
  health.apply(event("work.completed", { result: "blocked" }, 2), "s");
  health.apply(event("work.completed", { result: "failed", failureDetail: "Error: B" }, 3), "s");
  assert.equal(health.health("reviewer").state, "healthy");
  health.apply(event("work.completed", { result: "deferred", failureDetail: "Error: No supported model available", failureKind: "persistent" }, 4), "s");
  const failing = health.health("reviewer");
  assert.equal(failing.state, "failing");
  assert.equal(failing.source, "derived");
  assert.equal(failing.consecutiveFailures, 3);
  assert.equal(failing.cause, "Error: No supported model available");
  assert.equal(failing.failingSinceUtc, "2026-11-18T09:01:00.000Z");
  assert.equal(failing.lastSuccessUtc, "2026-11-18T09:00:00.000Z");
  assert.equal(health.health("review-handler").state, "healthy");

  health.apply(event("agent.health", {
    state: "stuck", consecutiveFailures: 0, cause: "", lastSuccessUtc: "2026-11-18T09:05:00Z",
    stuck: [{ pullRequestId: 42, sourceCommit: "a".repeat(40), outcome: "no-safe-progress", repeatCount: 12, nextAttemptUtc: "2026-11-18T13:00:00Z" }, { pullRequestId: -1 }],
  }, 5), "s");
  const reported = health.health("reviewer");
  assert.equal(reported.source, "agent");
  assert.equal(reported.state, "stuck");
  assert.deepEqual(reported.stuck.map((item) => [item.pullRequestId, item.repeatCount]), [[42, 12]]);
  health.apply(event("agent.health", { state: "failing" }, 4), "s");
  assert.equal(health.health("reviewer").state, "stuck", "older health events are ignored");
});

test("notification health counts failures since the last delivery and warns at three", () => {
  const health = new AgentHealthProjection();
  health.apply(event("notification.delivery", { outcome: "sent" }, 0), "s");
  health.apply(event("notification.delivery", { outcome: "deferred", code: "outbox-capacity" }, 1), "s");
  health.apply(event("notification.delivery", { outcome: "retrying", code: "ignored" }, 2), "s");
  health.apply(event("notification.delivery", { outcome: "failed", code: "reference-unavailable" }, 3), "s");
  assert.equal(health.notification("reviewer")!.warning, false);
  health.apply(event("notification.delivery", { outcome: "queued", reason: "Teams transport unavailable" }, 4), "s");
  const warning = health.notification("reviewer")!;
  assert.equal(warning.failuresSinceSuccess, 3);
  assert.equal(warning.latestReason, "Teams transport unavailable");
  assert.equal(warning.warning, true);
  health.apply(event("notification.delivery", { outcome: "delivered" }, 5), "s");
  assert.equal(health.notification("reviewer")!.failuresSinceSuccess, 0);
  assert.equal(health.notification("review-handler"), null);
});
