import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent, type AgentRole } from "../src/domain.js";
import { PullRequestHistoryProjection } from "../src/history.js";

function event(
  repositoryId: string,
  pullRequestId: number,
  sequence: number,
  options: { role?: AgentRole; instance?: string; timestamp?: string; type?: string; data?: Record<string, unknown> } = {},
) {
  const provider = repositoryId.includes("-") ? "AzureDevOps" : "GitHub";
  return parseAgentEvent({
    schemaVersion: 3,
    agent: options.role ?? "reviewer",
    instanceId: options.instance ?? "instance-a",
    processId: 1,
    timestamp: options.timestamp ?? `2026-09-03T00:00:${String(sequence).padStart(2, "0")}Z`,
    sequence,
    eventType: options.type ?? "candidate.selected",
    level: "info",
    cycleNumber: 1,
    pullRequestId,
    sourceCommit: `${sequence}`.repeat(40).slice(0, 40),
    repositoryIdentity: {
      schemaVersion: 1,
      provider,
      repositoryId,
      organization: "contoso",
      project: provider === "AzureDevOps" ? "widgets" : "",
      repositoryName: `repo-${repositoryId.slice(-3)}`,
      slug: provider === "AzureDevOps" ? `contoso/widgets/repo-${repositoryId.slice(-3)}` : `contoso/repo-${repositoryId.slice(-3)}`,
      key: `v1:${provider.toLowerCase()}:${repositoryId}`,
      verifiedAtUtc: "2026-09-03T00:00:00Z",
      verified: true,
      dispatchEligible: true,
    },
    dispatch: null,
    data: options.data ?? { title: `PR ${pullRequestId}`, author: "Ada" },
    message: "",
  });
}

test("history keys the same PR number independently by canonical repository identity", () => {
  const history = new PullRequestHistoryProjection();
  history.apply(event("9007199254740993", 42, 1));
  history.apply(event("9007199254740995", 42, 2));
  assert.equal(history.list().length, 2);
  assert.equal(history.jump(42), null);
  assert.equal(history.jump(42, "v1:github:9007199254740993")?.repositoryIdentity.repositoryId, "9007199254740993");
});

test("history merges only newer metadata and retains independent role outcomes", () => {
  const history = new PullRequestHistoryProjection();
  history.apply(event("9007199254740993", 7, 3, {
    timestamp: "2026-09-03T00:00:03Z",
    data: { title: "new title", author: "Ada" },
  }));
  history.apply(event("9007199254740993", 7, 2, {
    timestamp: "2026-09-03T00:00:02Z",
    data: { title: "stale title" },
  }));
  history.apply(event("9007199254740993", 7, 4, {
    role: "reviewer",
    type: "work.completed",
    data: { result: "reviewed" },
  }));
  history.apply(event("9007199254740993", 7, 5, {
    role: "review-handler",
    instance: "instance-b",
    type: "work.completed",
    data: { result: "handled" },
  }));
  const entry = history.list()[0]!;
  assert.equal(entry.title, "new title");
  assert.equal(entry.outcomes.reviewer?.result, "reviewed");
  assert.equal(entry.outcomes["review-handler"]?.result, "handled");
});

test("history filtering, hiding, restoring, and deterministic eviction are local", () => {
  const history = new PullRequestHistoryProjection(2);
  history.apply(event("9007199254740993", 1, 1, { data: { title: "Alpha", author: "Ada" } }));
  history.apply(event("9007199254740993", 2, 2, { data: { title: "Beta", author: "Grace" } }));
  history.apply(event("9007199254740993", 3, 3, { data: { title: "Gamma", author: "Linus" } }));
  assert.deepEqual(history.list().map((item) => item.pullRequestId), [3, 2]);
  assert.match(history.diagnostic(), /exceeded 2/);
  assert.equal(history.list("grace")[0]?.pullRequestId, 2);
  const key = history.list()[0]!.key;
  assert.equal(history.hide(key), true);
  assert.equal(history.list().some((item) => item.key === key), false);
  assert.equal(history.matches(3)[0]?.key, key);
  assert.equal(history.jump(3)?.key, key);
  assert.equal(history.restore(key), false);
  assert.equal(history.hideAll(), 2);
  assert.equal(history.list().length, 0);
  assert.equal(history.restoreAll(), 2);
  assert.equal(history.list().length, 2);
});

test("v2 and unverified events remain instance-observable but never enter PR history", () => {
  const history = new PullRequestHistoryProjection();
  const v2 = parseAgentEvent({
    ...event("9007199254740993", 5, 1),
    schemaVersion: 2,
    repositoryIdentity: undefined,
  });
  assert.equal(history.apply(v2), false);
  assert.equal(history.list().length, 0);
});
