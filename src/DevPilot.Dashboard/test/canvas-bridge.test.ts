import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CanvasBridge, type CanvasBridgeDiscovery, type CanvasBridgeOptions } from "../src/canvas-bridge.js";
import { AgentHealthProjection } from "../src/health.js";
import { parseAgentEvent } from "../src/domain.js";
import {
  BrokerRejectionError,
  type CapabilitySummary,
  type DispatchAccepted,
  type DispatchBroker,
  type RunPrepared,
  type RunProgress,
  type ScheduledDispatchAccepted,
} from "../src/dispatch.js";
import type { RepositoryIdentityV1 } from "../src/domain.js";
import { OperationsReducer } from "../src/reducer.js";

const identity: RepositoryIdentityV1 = {
  schemaVersion: 1, provider: "AzureDevOps", repositoryId: "11111111-1111-1111-1111-111111111111",
  organization: "contoso", project: "payments", repositoryName: "api", slug: "contoso/payments/api",
  key: "v1:azuredevops:11111111-1111-1111-1111-111111111111", verifiedAtUtc: "2026-11-10T00:00:00Z",
  verified: true, dispatchEligible: true,
};

function summary(pullRequestId = 42): CapabilitySummary {
  return {
    schemaVersion: 1, requestId: "r", operation: "capability-summary", role: "reviewer",
    dispatchDraftId: `draft-${pullRequestId}`, repositoryIdentity: identity,
    prSnapshot: {
      schemaVersion: 1, pullRequestId, sourceCommit: "a".repeat(40), sourceRef: "refs/heads/feature",
      targetRef: "refs/heads/main", active: true, draft: false, author: "dev", title: "Retry keys",
    },
    capabilityPolicyDigest: "digest", prStateFingerprint: "fingerprint", capabilities: ["EnableComments"],
    mandatoryDenies: ["EnableApprovalVote"], dynamicConstraints: [], absoluteDenies: [], allowedManualCapabilities: [],
    delegableAvailable: [], provenance: {}, killSwitchActive: false, killSwitchExpiresAtUtc: null, editingAvailable: true,
    scheduling: { version: 1, scope: "current-launcher" },
  };
}

function accepted(dispatchId: string, queueId?: string): DispatchAccepted {
  return {
    schemaVersion: 1, requestId: "r", operation: "accepted", dispatchId, repositoryIdentity: identity,
    pullRequestId: 42, role: "reviewer", capabilityPolicyDigest: "digest", prStateFingerprint: "fingerprint",
    childProcessId: 4242, eventLogPath: join(tmpdir(), `${dispatchId}.jsonl`), ...(queueId ? { queueId } : {}),
  };
}

interface Harness {
  bridge: CanvasBridge;
  discovery: CanvasBridgeDiscovery;
  discoveryFile: string;
  calls: Array<{ method: string; args: unknown[] }>;
  registered: string[];
  emitScheduledAccepted: (event: ScheduledDispatchAccepted) => void;
  cleanup: () => Promise<void>;
}

async function startHarness(
  overrides: Partial<Record<keyof DispatchBroker, unknown>> = {},
  onShutdown?: () => void,
  extra: Partial<CanvasBridgeOptions> = {},
): Promise<Harness> {
  const directory = await mkdtemp(join(tmpdir(), "canvas-bridge-"));
  const calls: Harness["calls"] = [];
  let scheduledAccepted: (event: ScheduledDispatchAccepted) => void = () => {};
  const record = (method: string, result: (...args: unknown[]) => unknown) =>
    async (...args: unknown[]) => { calls.push({ method, args }); return result(...args); };
  const broker = {
    profileCurrent: record("profileCurrent", () => ({ ...summary(), operation: "capability-profile" })),
    describe: record("describe", () => summary()),
    dispatch: record("dispatch", () => accepted("d-1")),
    cancel: record("cancel", (id) => ({ schemaVersion: 1, requestId: "r", operation: "cancelled", dispatchId: id })),
    getAutomationStatus: record("getAutomationStatus", () => ({
      schemaVersion: 1, requestId: "r", operation: "automation-status", automationVersion: 1, available: true,
      scope: "current-launcher", agents: [],
    })),
    subscribeTerminal: () => () => {},
    subscribeSchedule: () => () => {},
    subscribeScheduledAccepted: (listener: (event: ScheduledDispatchAccepted) => void) => {
      scheduledAccepted = listener;
      return () => {};
    },
    ...overrides,
  } as unknown as DispatchBroker;
  const registered: string[] = [];
  const discoveryFile = join(directory, "canvas-bridge.v1.json");
  const bridge = new CanvasBridge({
    discoveryFile, consumerRepositoryRoot: "C:\\repo", launchMode: "operational", broker,
    reducer: new OperationsReducer(), tailer: { registerEventLogPath: (path: string) => { registered.push(path); return true; } },
    onShutdown,
    ...extra,
  });
  const discovery = await bridge.start();
  return {
    bridge, discovery, discoveryFile, calls, registered,
    emitScheduledAccepted: (event) => scheduledAccepted(event),
    cleanup: async () => { bridge.stop(); await rm(directory, { recursive: true, force: true }); },
  };
}

function call(
  harness: Harness, method: string, path: string, body?: unknown,
  headers: Record<string, string> = {},
): Promise<{ status: number; body: Record<string, unknown> }> {
  const url = new URL(path, harness.discovery.url);
  const payload = body === undefined ? undefined : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = request(url, {
      method,
      headers: {
        authorization: `Bearer ${harness.discovery.token}`,
        ...(payload ? { "content-type": "application/json" } : {}),
        ...headers,
      },
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => resolve({ status: res.statusCode ?? 0, body: text ? JSON.parse(text) : {} }));
    });
    req.on("error", reject);
    req.end(payload);
  });
}

test("canvas bridge only serves authenticated loopback callers and never exposes widening or shutdown", async () => {
  const harness = await startHarness();
  try {
    const published = JSON.parse(readFileSync(harness.discoveryFile, "utf8")) as CanvasBridgeDiscovery;
    assert.equal(published.token, harness.discovery.token);
    assert.equal(published.consumerRepositoryRoot, "C:\\repo");
    assert.match(published.url, /^http:\/\/127\.0\.0\.1:\d+\/$/);
    assert.equal(published.headless, false);

    assert.equal((await call(harness, "GET", "/v1/status", undefined, { authorization: "Bearer wrong" })).status, 401);
    assert.equal((await call(harness, "GET", "/v1/status", undefined, { host: "localhost" })).status, 403);
    const status = await call(harness, "GET", "/v1/status?view=live");
    assert.equal(status.status, 200);
    assert.equal(status.body.launchMode, "operational");
    for (const path of ["/v1/review/describe-widening", "/v1/review/confirm-widening-mint", "/v1/settings/kill-switch", "/v1/shutdown"]) {
      assert.equal((await call(harness, "POST", path, {})).status, 404, path);
    }
  } finally {
    await harness.cleanup();
  }
  assert.equal(existsSync(harness.discoveryFile), false);
});

test("only a headless owner bridge advertises headless and accepts the canvas Stop", async () => {
  let stopped = 0;
  const harness = await startHarness({}, () => { stopped++; });
  try {
    const published = JSON.parse(readFileSync(harness.discoveryFile, "utf8")) as CanvasBridgeDiscovery;
    assert.equal(published.headless, true);
    assert.equal((await call(harness, "GET", "/v1/status")).body.headless, true);
    assert.equal((await call(harness, "POST", "/v1/shutdown", {}, { authorization: "Bearer wrong" })).status, 401);
    assert.equal(stopped, 0);
    const response = await call(harness, "POST", "/v1/shutdown", {});
    assert.equal(response.status, 200);
    assert.equal(response.body.stopping, true);
    await new Promise((resolveWait) => setTimeout(resolveWait, 120));
    assert.equal(stopped, 1);
  } finally {
    await harness.cleanup();
  }
});

test("canvas bridge starts exactly the previewed broker draft once and bounds instructions", async () => {
  const harness = await startHarness();
  try {
    const preview = await call(harness, "POST", "/v1/review/describe", { pullRequestId: 42, role: "reviewer" });
    assert.equal(preview.status, 200);
    assert.equal(preview.body.dispatchDraftId, "draft-42");
    assert.deepEqual(harness.calls.map((item) => item.method), ["profileCurrent", "describe"]);

    const tooLong = await call(harness, "POST", "/v1/review/dispatch", { dispatchDraftId: "draft-42", operatorPrompt: "x".repeat(513) });
    assert.equal(tooLong.status, 400);
    assert.equal(harness.calls.some((item) => item.method === "dispatch"), false);

    const started = await call(harness, "POST", "/v1/review/dispatch", { dispatchDraftId: "draft-42", operatorPrompt: "focus on retries" });
    assert.equal(started.status, 200);
    assert.equal(started.body.dispatchId, "d-1");
    const dispatched = harness.calls.find((item) => item.method === "dispatch")!;
    assert.deepEqual(dispatched.args, [summary(), "focus on retries"]);
    assert.deepEqual(harness.registered, [accepted("d-1").eventLogPath]);

    const replay = await call(harness, "POST", "/v1/review/dispatch", { dispatchDraftId: "draft-42" });
    assert.equal(replay.status, 404);
    assert.equal(replay.body.error, "unknown-draft");
    const runs = (await call(harness, "GET", "/v1/status")).body.runs as Array<{ dispatchId: string }>;
    assert.deepEqual(runs.map((run) => run.dispatchId), ["d-1"]);
  } finally {
    await harness.cleanup();
  }
});

test("canvas bridge offers Replace or Run next when busy and tracks the confirmed queued run", async () => {
  let prepared: RunPrepared | undefined;
  const harness = await startHarness({
    dispatch: async () => { throw new BrokerRejectionError("already-running", "lease held"); },
    prepareRun: async (draft: CapabilitySummary, mode: "replace" | "next") => {
      prepared = {
        schemaVersion: 1, requestId: "r", operation: "run-prepared", schedulingVersion: 1, scope: "current-launcher",
        confirmationToken: "token-1", expiresAtUtc: new Date(Date.now() + 60_000).toISOString(),
        repositoryKey: draft.repositoryIdentity.key, role: draft.role, pullRequestId: draft.prSnapshot.pullRequestId, mode,
        conflict: { kind: "automatic", workId: "w", generation: "g", pullRequestId: 7 },
      };
      return prepared;
    },
    confirmRun: async (value: RunPrepared) => {
      assert.deepEqual(value, prepared);
      return { schemaVersion: 1, requestId: "r", operation: "run-queued", schedulingVersion: 1, queueId: "q-1", mode: value.mode };
    },
  });
  try {
    await call(harness, "POST", "/v1/review/describe", { pullRequestId: 42, role: "reviewer" });
    const busy = await call(harness, "POST", "/v1/review/dispatch", { dispatchDraftId: "draft-42" });
    assert.equal(busy.status, 409);
    assert.equal(busy.body.error, "already-running");

    const proposal = await call(harness, "POST", "/v1/review/prepare-run", { dispatchDraftId: "draft-42", mode: "next" });
    assert.equal(proposal.status, 200);
    assert.deepEqual(proposal.body.conflict, { kind: "automatic", pullRequestId: 7 });
    assert.equal((await call(harness, "POST", "/v1/review/confirm-run", { confirmationToken: "token-1" })).status, 200);
    assert.equal((await call(harness, "POST", "/v1/review/confirm-run", { confirmationToken: "token-1" })).status, 404);

    let status = (await call(harness, "GET", "/v1/status")).body;
    assert.deepEqual((status.queued as Array<{ queueId: string }>).map((item) => item.queueId), ["q-1"]);
    harness.emitScheduledAccepted(accepted("d-2", "q-1") as ScheduledDispatchAccepted);
    status = (await call(harness, "GET", "/v1/status")).body;
    assert.deepEqual(status.queued, []);
    assert.deepEqual((status.runs as Array<{ dispatchId: string; queueId: string }>).map((run) => [run.dispatchId, run.queueId]), [["d-2", "q-1"]]);
  } finally {
    await harness.cleanup();
  }
});

test("canvas bridge serves Live by default (accepting legacy view=current) and per-PR History with persisted hides", async () => {
  const { parseAgentEvent } = await import("../src/domain.js");
  const { PullRequestHistoryProjection } = await import("../src/history.js");
  const history = new PullRequestHistoryProjection();
  history.apply(parseAgentEvent({
    schemaVersion: 3, agent: "reviewer", instanceId: "i-1", processId: 1, timestamp: "2026-11-10T00:00:01Z", sequence: 1,
    eventType: "review.completed", level: "info", cycleNumber: 1, pullRequestId: 42, sourceCommit: "a".repeat(40),
    repositoryIdentity: identity, dispatch: null, data: { title: "Fix it", author: "Ada", result: "approved" }, message: "",
  })!);
  const saved: Array<{ hiddenKeys: string[]; clearedThroughMs: number }> = [];
  const directory = await mkdtemp(join(tmpdir(), "canvas-bridge-history-"));
  const bridge = new CanvasBridge({
    discoveryFile: join(directory, "canvas-bridge.v1.json"), consumerRepositoryRoot: "C:\\repo", launchMode: "operational",
    broker: { subscribeTerminal: () => () => {} } as unknown as DispatchBroker,
    reducer: new OperationsReducer(), tailer: { registerEventLogPath: () => true },
    history, historyHides: { load: async () => ({ hiddenKeys: [], clearedThroughMs: 0 }), save: async (value) => { saved.push(value); } },
    now: () => Date.parse("2026-11-11T00:00:00Z"),
  });
  const discovery = await bridge.start();
  const harness = { discovery } as unknown as Harness;
  try {
    for (const path of ["/v1/status", "/v1/status?view=current"]) {
      const status = await call(harness, "GET", path);
      assert.equal(status.body.view, "live", path);
      assert.equal(status.body.pullRequests, undefined);
      assert.deepEqual(status.body.recentPullRequests, [{ pullRequestId: 42, title: "Fix it", repository: identity.slug }]);
    }
    const historyStatus = await call(harness, "GET", "/v1/status?view=history");
    const rows = historyStatus.body.pullRequests as Array<Record<string, unknown>>;
    assert.equal(rows.length, 1);
    assert.equal(rows[0]!.pullRequestId, 42);
    assert.deepEqual((rows[0]!.reviewer as Record<string, unknown>).result, "approved");
    const key = rows[0]!.key as string;

    assert.equal((await call(harness, "POST", "/v1/history/hide", { key: "x\u0000:pr:1" })).status, 400);
    assert.equal((await call(harness, "POST", "/v1/history/hide", { key: `${identity.key}:pr:7` })).status, 404);
    assert.equal((await call(harness, "POST", "/v1/history/hide", { key })).status, 200);
    assert.deepEqual(saved.at(-1), { hiddenKeys: [key], clearedThroughMs: 0 });
    const hidden = await call(harness, "GET", "/v1/status?view=history");
    assert.deepEqual(hidden.body.pullRequests, []);
    assert.equal(hidden.body.hiddenPullRequestCount, 1);

    assert.equal((await call(harness, "POST", "/v1/history/restore", {})).body.restored, 1);
    assert.equal((await call(harness, "POST", "/v1/history/clear", {})).body.hidden, 1);
    assert.equal(saved.at(-1)!.clearedThroughMs, Date.parse("2026-11-11T00:00:00Z"));
    assert.deepEqual((await call(harness, "GET", "/v1/status?view=history")).body.pullRequests, []);
  } finally {
    bridge.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("canvas Live keeps running-but-stale instances (with stale status) out of History", async () => {
  const { parseAgentEvent } = await import("../src/domain.js");
  const reducer = new OperationsReducer();
  reducer.apply(parseAgentEvent({
    schemaVersion: 3, agent: "reviewer", instanceId: "quiet", processId: 7, timestamp: "2026-11-10T00:00:00Z", sequence: 1,
    eventType: "agent.started", level: "info", cycleNumber: 1, pullRequestId: null, sourceCommit: null,
    repositoryIdentity: identity, dispatch: null, data: {}, message: "",
  })!);
  const directory = await mkdtemp(join(tmpdir(), "canvas-bridge-stale-"));
  const bridge = new CanvasBridge({
    discoveryFile: join(directory, "canvas-bridge.v1.json"), consumerRepositoryRoot: "C:\\repo", launchMode: "operational",
    broker: { subscribeTerminal: () => () => {} } as unknown as DispatchBroker,
    reducer, tailer: { registerEventLogPath: () => true },
    now: () => Date.parse("2026-11-10T00:05:00Z"),
  });
  const harness = { discovery: await bridge.start() } as unknown as Harness;
  try {
    const live = (await call(harness, "GET", "/v1/status")).body.instances as Array<{ instanceId: string; status: string }>;
    assert.deepEqual(live.map((item) => [item.instanceId, item.status]), [["quiet", "stale"]]);
    assert.deepEqual((await call(harness, "GET", "/v1/status?view=history")).body.instances, []);
  } finally {
    bridge.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("file-backed PR history hides survive a new storage instance and reject invalid records", async () => {
  const { FileHistoryHideStorage } = await import("../src/history-hides.js");
  const { writeFile } = await import("node:fs/promises");
  const directory = await mkdtemp(join(tmpdir(), "history-hides-"));
  const file = join(directory, "nested", "hidden-pr-history.v1.json");
  try {
    assert.deepEqual(await new FileHistoryHideStorage(file).load(), { hiddenKeys: [], clearedThroughMs: 0 });
    const key = `${identity.key}:pr:42`;
    await new FileHistoryHideStorage(file).save({ hiddenKeys: [key, key], clearedThroughMs: 5 });
    assert.deepEqual(await new FileHistoryHideStorage(file).load(), { hiddenKeys: [key], clearedThroughMs: 5 });
    await assert.rejects(new FileHistoryHideStorage(file).save({ hiddenKeys: ["bad\u0000:pr:1"], clearedThroughMs: 0 }));
    await writeFile(file, JSON.stringify({ hiddenKeys: ["not-a-key"], clearedThroughMs: 0 }));
    await assert.rejects(new FileHistoryHideStorage(file).load(), /Invalid/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("a queued run retired before any dispatch leaves the queue and is reported as not run", async () => {
  let schedule: (event: RunProgress) => void = () => {};
  let nextQueue = 0;
  const harness = await startHarness({
    dispatch: async () => { throw new BrokerRejectionError("already-running", "lease held"); },
    prepareRun: async (draft: CapabilitySummary, mode: "replace" | "next") => ({
      schemaVersion: 1, requestId: "r", operation: "run-prepared", schedulingVersion: 1, scope: "current-launcher",
      confirmationToken: `token-${++nextQueue}`, expiresAtUtc: new Date(Date.now() + 60_000).toISOString(),
      repositoryKey: draft.repositoryIdentity.key, role: draft.role, pullRequestId: draft.prSnapshot.pullRequestId, mode,
      conflict: { kind: "automatic", workId: "w", generation: "g", pullRequestId: 7 },
    }),
    confirmRun: async (value: RunPrepared) => ({
      schemaVersion: 1, requestId: "r", operation: "run-queued", schedulingVersion: 1,
      queueId: `q-${value.confirmationToken.slice(6)}`, mode: value.mode,
    }),
    subscribeSchedule: (listener: (event: RunProgress) => void) => { schedule = listener; return () => {}; },
  });
  const progress = (queueId: string, state: RunProgress["state"]): RunProgress =>
    ({ schemaVersion: 1, requestId: "r", operation: "run-progress", schedulingVersion: 1, queueId, state, code: "" });
  try {
    for (const _ of [1, 2]) {
      await call(harness, "POST", "/v1/review/describe", { pullRequestId: 42, role: "reviewer" });
      const proposal = await call(harness, "POST", "/v1/review/prepare-run", { dispatchDraftId: "draft-42", mode: "replace" });
      assert.equal((await call(harness, "POST", "/v1/review/confirm-run", { confirmationToken: proposal.body.confirmationToken })).status, 200);
    }
    schedule(progress("q-1", "waiting-authority"));
    schedule(progress("q-1", "resumed"));
    harness.emitScheduledAccepted(accepted("d-2", "q-2") as ScheduledDispatchAccepted);
    schedule(progress("q-2", "resumed"));
    const status = (await call(harness, "GET", "/v1/status")).body;
    assert.deepEqual(status.queued, []);
    const notRun = status.notRun as Array<{ queueId: string; pullRequestId: number; retiredAtUtc: string }>;
    assert.deepEqual(notRun.map((item) => [item.queueId, item.pullRequestId]), [["q-1", 42]]);
    assert.ok(Number.isFinite(Date.parse(notRun[0]!.retiredAtUtc)));
    assert.deepEqual((status.runs as Array<{ dispatchId: string }>).map((run) => run.dispatchId), ["d-2"]);
  } finally {
    await harness.cleanup();
  }
});

function agentEvent(eventType: string, data: Record<string, unknown>, extra: Record<string, unknown> = {}) {
  return parseAgentEvent({
    schemaVersion: 3, agent: "reviewer", instanceId: "watch-1", processId: 7, sequence: 1,
    timestamp: "2026-11-18T10:00:00.000Z", eventType, level: "warning", cycleNumber: 1,
    pullRequestId: 15461706, sourceCommit: "a1d09dfe".padEnd(40, "0"), repositoryIdentity: identity, data, message: "", ...extra,
  });
}

test("failure-log route serves only recorded logs inside a watch state root, capped and redacted", async () => {
  const root = await mkdtemp(join(tmpdir(), "canvas-watch-"));
  const outside = await mkdtemp(join(tmpdir(), "canvas-outside-"));
  const failed = join(root, "reviewer", "logs", "failed-cycles");
  mkdirSync(failed, { recursive: true });
  const log = join(failed, "pr1-cycle1.txt");
  const big = join(failed, "pr1-cycle2.txt");
  const stray = join(outside, "secret.txt");
  writeFileSync(log, "STDERR\n\u001b[31mError: No supported model available\u001b[0m\nAuthorization: Bearer abc\n" +
    "remote: https://x-access-token:ghp_abcdefghijklmnop@github.com/o/r\npassword=hunter2\n\"token\": \"eyJhbGciOiJIUzI1NiJ9.e30.x\"\n");
  writeFileSync(big, `${"x".repeat(70 * 1024)}\nError: tail`);
  writeFileSync(stray, "nope");
  const unc = "\\\\devpilot-unreachable-host\\share\\pr1.txt";
  const health = new AgentHealthProjection();
  const source = join(root, "reviewer", "logs", "events", "reviewer", "events.jsonl");
  for (const path of [log, big, stray, unc]) {
    health.apply(agentEvent("work.completed", { result: "failed", failureDetail: "Error: x", failureLogPath: path }), source);
  }
  const harness = await startHarness({}, undefined, { health, stateRoots: [root] });
  try {
    assert.equal((await call(harness, "POST", "/v1/agents/failure-log", { path: log }, { authorization: "Bearer wrong" })).status, 401);
    const ok = await call(harness, "POST", "/v1/agents/failure-log", { path: log });
    assert.equal(ok.status, 200);
    assert.match(String(ok.body.content), /^STDERR\nError: No supported model available\n\[line redacted/);
    assert.doesNotMatch(String(ok.body.content), /Bearer abc|ghp_abcdefghijklmnop|hunter2|eyJhbGci/);
    const capped = await call(harness, "POST", "/v1/agents/failure-log", { path: big });
    assert.equal(capped.body.truncated, true);
    assert.equal(String(capped.body.content).length, 64 * 1024);
    assert.match(String(capped.body.content), /Error: tail$/);
    assert.equal((await call(harness, "POST", "/v1/agents/failure-log", { path: stray })).status, 403);
    assert.equal((await call(harness, "POST", "/v1/agents/failure-log", { path: unc })).status, 403);
    assert.equal((await call(harness, "POST", "/v1/agents/failure-log", { path: join(failed, "other.txt") })).status, 404);
    assert.equal((await call(harness, "POST", "/v1/agents/failure-log", { path: "relative.txt" })).status, 400);
    assert.equal((await call(harness, "POST", "/v1/agents/failure-log", { path: 5 })).status, 400);
  } finally {
    await harness.cleanup();
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  }
});

test("skip route validates, resolves the target server-side and writes the skip file atomically", async () => {
  const root = await mkdtemp(join(tmpdir(), "canvas-watch-"));
  mkdirSync(join(root, "reviewer", "logs"), { recursive: true });
  const source = join(root, "reviewer", "logs", "events.jsonl");
  writeFileSync(source, "");
  const health = new AgentHealthProjection();
  health.apply(agentEvent("agent.health", {
    state: "stuck", consecutiveFailures: 0, stuck: [{ pullRequestId: 15461706, sourceCommit: "b".repeat(40), outcome: "no-safe-progress", repeatCount: 12 }],
  }), source);
  const file = join(root, "reviewer", "skipped-prs.json");
  writeFileSync(file, JSON.stringify({ schemaVersion: 1, entries: [
    ...Array.from({ length: 200 }, (_, index) => ({ repositoryKey: identity.key, pullRequestId: index + 1, sourceCommit: "c".repeat(40), skippedAtUtc: "2026-11-01T00:00:00Z" })),
    { repositoryKey: "bad", pullRequestId: 1, sourceCommit: "c".repeat(40), skippedAtUtc: "2026-11-01T00:00:00Z" },
  ] }));
  const harness = await startHarness({}, undefined, { health, stateRoots: [root], now: () => Date.parse("2026-11-18T12:00:00Z") });
  try {
    const body = { role: "reviewer", pullRequestId: 15461706 };
    assert.equal((await call(harness, "POST", "/v1/agents/skip", body, { authorization: "Bearer wrong" })).status, 401);
    assert.equal((await call(harness, "POST", "/v1/agents/skip", body, { host: "localhost" })).status, 403);
    assert.equal((await call(harness, "POST", "/v1/agents/skip", { ...body, sourceCommit: "d".repeat(40) })).status, 400);
    assert.equal((await call(harness, "POST", "/v1/agents/skip", { ...body, role: "fixer" })).status, 400);
    assert.equal((await call(harness, "POST", "/v1/agents/skip", { ...body, pullRequestId: -1 })).status, 400);
    assert.equal((await call(harness, "POST", "/v1/agents/skip", { ...body, pullRequestId: 99 })).status, 404);
    assert.equal((await call(harness, "POST", "/v1/agents/skip", { role: "review-handler", pullRequestId: 15461706 })).status, 404);
    const ok = await call(harness, "POST", "/v1/agents/skip", body);
    assert.equal(ok.status, 200);
    assert.equal(ok.body.sourceCommit, "b".repeat(40));
    const written = JSON.parse(readFileSync(file, "utf8"));
    assert.equal(written.schemaVersion, 1);
    assert.equal(written.entries.length, 200);
    assert.deepEqual(written.entries.at(-1), {
      repositoryKey: identity.key, pullRequestId: 15461706, sourceCommit: "b".repeat(40), skippedAtUtc: "2026-11-18T12:00:00.000Z",
    });
    assert.equal(written.entries[0].pullRequestId, 2);
    assert.equal(written.entries.some((entry: { repositoryKey: string }) => entry.repositoryKey === "bad"), false);
    const status = await call(harness, "GET", "/v1/status");
    const reviewer = (status.body.health as Array<Record<string, unknown>>).find((item) => item.role === "reviewer")!;
    assert.equal(reviewer.state, "stuck");
  } finally {
    await harness.cleanup();
    await rm(root, { recursive: true, force: true });
  }
});