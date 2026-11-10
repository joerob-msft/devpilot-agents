import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CanvasBridge, type CanvasBridgeDiscovery } from "../src/canvas-bridge.js";
import {
  BrokerRejectionError,
  type CapabilitySummary,
  type DispatchAccepted,
  type DispatchBroker,
  type RunPrepared,
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

async function startHarness(overrides: Partial<Record<keyof DispatchBroker, unknown>> = {}): Promise<Harness> {
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
