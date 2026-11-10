import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname } from "node:path";
import {
  BrokerRejectionError,
  assertManualTarget,
  isPullRequestId,
  type AutomationStatus,
  type CapabilitySummary,
  type DispatchAccepted,
  type DispatchBroker,
  type DispatchTerminal,
  type RunPrepared,
  type RunProgress,
  type RunScheduleMode,
  type ScheduledDispatchAccepted,
} from "./dispatch.js";
import { AGENTS, type AgentRole, type InstanceState, type ViewFilter } from "./domain.js";
import { eventNarrative } from "./format.js";
import { manualProgress } from "./manual-progress.js";
import { liveElapsedMilliseconds, totalElapsedMilliseconds, type OperationsReducer } from "./reducer.js";
import type { EventTailer } from "./tailer.js";

// Opt-in loopback bridge that lets the Copilot app canvas (src/DevPilot.CopilotCanvas) observe this
// dashboard and stage manual runs through the dashboard's own trusted broker client. The broker,
// its launch provenance and the descriptor are untouched: the bridge is just another in-process
// caller of DispatchClient. It deliberately exposes no widening, narrowing, kill-switch or shutdown.
// It is owner-agnostic (no renderer dependency) so a future headless Golden owner can host it too.
export const CANVAS_BRIDGE_SCHEMA_VERSION = 1;
const MAX_BODY_BYTES = 16 * 1024;
const MAX_PROMPT_SCALARS = 512;
const MAX_DRAFTS = 8;
const MAX_RUNS = 20;
const TIMELINE_ITEMS = 15;
const AUTOMATION_CACHE_MS = 2_000;
const BUSY_CODES = new Set(["already-running", "state-contended"]);

type BridgeReducer = Pick<OperationsReducer, "list" | "getDispatch" | "registerLocalStream">;

export interface CanvasBridgeOptions {
  discoveryFile: string;
  consumerRepositoryRoot: string;
  launchMode: string;
  broker: DispatchBroker;
  reducer: BridgeReducer;
  tailer: Pick<EventTailer, "registerEventLogPath">;
  now?: () => number;
  token?: string;
}

export interface CanvasBridgeDiscovery {
  schemaVersion: 1;
  url: string;
  token: string;
  dashboardPid: number;
  consumerRepositoryRoot: string;
  launchMode: string;
  startedAtUtc: string;
}

interface BridgeRun {
  accepted: DispatchAccepted;
  startedMs: number;
  terminal: DispatchTerminal | null;
  terminalMs: number | null;
  cancelling: boolean;
}

interface BridgeQueued {
  queueId: string;
  mode: RunScheduleMode;
  role: AgentRole;
  pullRequestId: number;
  progress: RunProgress | null;
  dispatchId: string | null;
  cancelled: boolean;
}

class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message = code) {
    super(message);
  }
}

export class CanvasBridge {
  private readonly token: string;
  private readonly now: () => number;
  private server: Server | undefined;
  private host = "";
  private written = false;
  private readonly drafts = new Map<string, CapabilitySummary>();
  private readonly prepared = new Map<string, RunPrepared>();
  private readonly runs = new Map<string, BridgeRun>();
  private readonly queued = new Map<string, BridgeQueued>();
  private readonly unsubscribe: Array<() => void> = [];
  private automation: { at: number; value: AutomationStatus | null; error: string } | undefined;

  constructor(private readonly options: CanvasBridgeOptions) {
    this.token = options.token ?? randomBytes(32).toString("base64url");
    this.now = options.now ?? Date.now;
  }

  async start(): Promise<CanvasBridgeDiscovery> {
    const broker = this.options.broker;
    this.unsubscribe.push(broker.subscribeTerminal((event) => this.onTerminal(event)));
    const offSchedule = broker.subscribeSchedule?.((event) => this.onSchedule(event));
    if (offSchedule) this.unsubscribe.push(offSchedule);
    const offAccepted = broker.subscribeScheduledAccepted?.((event) => this.onScheduledAccepted(event));
    if (offAccepted) this.unsubscribe.push(offAccepted);

    const server = createServer((req, res) => void this.handle(req, res));
    this.server = server;
    await new Promise<void>((resolveListen, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolveListen());
    });
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("canvas bridge did not bind a TCP port");
    this.host = `127.0.0.1:${address.port}`;
    const discovery: CanvasBridgeDiscovery = {
      schemaVersion: CANVAS_BRIDGE_SCHEMA_VERSION,
      url: `http://${this.host}/`,
      token: this.token,
      dashboardPid: process.pid,
      consumerRepositoryRoot: this.options.consumerRepositoryRoot,
      launchMode: this.options.launchMode,
      startedAtUtc: new Date(this.now()).toISOString(),
    };
    writeDiscoveryFile(this.options.discoveryFile, discovery);
    this.written = true;
    return discovery;
  }

  // Synchronous so it is safe from process "exit" handlers and renderer teardown.
  stop(): void {
    for (const off of this.unsubscribe.splice(0)) off();
    if (this.server) {
      this.server.closeAllConnections();
      this.server.close();
      this.server = undefined;
    }
    if (this.written) {
      rmSync(this.options.discoveryFile, { force: true });
      this.written = false;
    }
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    try {
      if (req.headers.host !== this.host) throw new HttpError(403, "invalid-host");
      if (!this.authorized(req.headers.authorization)) throw new HttpError(401, "unauthorized");
      const url = new URL(req.url ?? "/", `http://${this.host}`);
      const route = `${req.method ?? ""} ${url.pathname}`;
      let body: Record<string, unknown> = {};
      if (req.method === "POST") body = await readJsonBody(req);
      const result = await this.route(route, url, body);
      send(res, 200, result);
    } catch (error) {
      if (error instanceof HttpError) {
        send(res, error.status, { error: error.code, detail: error.message === error.code ? "" : error.message });
      } else if (error instanceof BrokerRejectionError) {
        send(res, 409, { error: error.code, detail: error.detail });
      } else {
        send(res, 500, { error: "bridge-error", detail: error instanceof Error ? error.message : String(error) });
      }
    }
  }

  private authorized(header: string | undefined): boolean {
    const expected = Buffer.from(`Bearer ${this.token}`);
    const actual = Buffer.from(header ?? "");
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  }

  private async route(route: string, url: URL, body: Record<string, unknown>): Promise<unknown> {
    switch (route) {
      case "GET /v1/status": return this.status(url.searchParams.get("view"));
      case "POST /v1/scan-now": return this.scanNow();
      case "POST /v1/review/describe": return this.describe(body);
      case "POST /v1/review/dispatch": return this.dispatch(body);
      case "POST /v1/review/prepare-run": return this.prepareRun(body);
      case "POST /v1/review/confirm-run": return this.confirmRun(body);
      case "POST /v1/review/cancel-queued": return this.cancelQueued(body);
      case "POST /v1/review/cancel": return this.cancel(body);
      default: throw new HttpError(404, "not-found");
    }
  }

  private async status(viewParameter: string | null): Promise<unknown> {
    const view: ViewFilter = viewParameter === "live" || viewParameter === "history" ? viewParameter : "current";
    const now = this.now();
    return {
      schemaVersion: CANVAS_BRIDGE_SCHEMA_VERSION,
      launchMode: this.options.launchMode,
      consumerRepositoryRoot: this.options.consumerRepositoryRoot,
      dashboardPid: process.pid,
      view,
      automation: await this.automationStatus(now),
      instances: this.options.reducer.list(now, undefined, view).map((state) => instanceView(state, now)),
      runs: [...this.runs.values()].map((run) => this.runView(run, now)),
      queued: [...this.queued.values()].filter((item) => !item.dispatchId && !item.cancelled)
        .map((item) => ({ queueId: item.queueId, mode: item.mode, role: item.role, pullRequestId: item.pullRequestId,
          state: item.progress?.state ?? "queued", code: item.progress?.code ?? "" })),
    };
  }

  private async automationStatus(now: number): Promise<unknown> {
    const getStatus = this.options.broker.getAutomationStatus?.bind(this.options.broker);
    if (!getStatus) return { available: false, error: "" };
    if (!this.automation || now - this.automation.at >= AUTOMATION_CACHE_MS) {
      try {
        this.automation = { at: now, value: await getStatus(), error: "" };
      } catch (error) {
        this.automation = { at: now, value: null, error: error instanceof Error ? error.message : String(error) };
      }
    }
    const { value, error } = this.automation;
    return value
      ? { available: value.available, scope: value.scope, agents: value.agents, error: "" }
      : { available: false, error };
  }

  private async scanNow(): Promise<unknown> {
    if (!this.options.broker.scanNow) throw new HttpError(409, "scan-unavailable");
    const result = await this.options.broker.scanNow();
    this.automation = undefined;
    return { results: result.results };
  }

  private async describe(body: Record<string, unknown>): Promise<unknown> {
    const pullRequestId = body.pullRequestId;
    const role = body.role;
    if (!isPullRequestId(pullRequestId)) throw new HttpError(400, "invalid-pull-request-id");
    if (typeof role !== "string" || !(AGENTS as readonly string[]).includes(role)) throw new HttpError(400, "invalid-role");
    const agentRole = role as AgentRole;
    // Same two-step resolution as the TUI: read-only profile first, then a fresh keyed draft.
    const profile = await this.options.broker.profileCurrent(pullRequestId, agentRole);
    assertManualTarget(profile, pullRequestId, agentRole);
    const summary = await this.options.broker.describe(profile.repositoryIdentity.key, pullRequestId, agentRole);
    assertManualTarget(summary, pullRequestId, agentRole, profile.repositoryIdentity.key);
    this.drafts.set(summary.dispatchDraftId, summary);
    while (this.drafts.size > MAX_DRAFTS) this.drafts.delete(this.drafts.keys().next().value!);
    return {
      dispatchDraftId: summary.dispatchDraftId,
      role: summary.role,
      repository: {
        provider: summary.repositoryIdentity.provider,
        slug: summary.repositoryIdentity.slug,
        key: summary.repositoryIdentity.key,
      },
      pullRequest: summary.prSnapshot,
      capabilities: summary.capabilities,
      mandatoryDenies: summary.mandatoryDenies,
      absoluteDenies: summary.absoluteDenies,
      dynamicConstraints: summary.dynamicConstraints,
      killSwitchActive: summary.killSwitchActive,
      schedulingAvailable: schedulingAvailable(summary),
    };
  }

  private async dispatch(body: Record<string, unknown>): Promise<unknown> {
    const summary = this.draft(body.dispatchDraftId);
    const prompt = operatorPrompt(body.operatorPrompt);
    try {
      const accepted = await this.options.broker.dispatch(summary, prompt);
      this.drafts.delete(summary.dispatchDraftId);
      this.track(accepted);
      return { state: "accepted", dispatchId: accepted.dispatchId, childProcessId: accepted.childProcessId };
    } catch (error) {
      if (error instanceof BrokerRejectionError && BUSY_CODES.has(error.code) && schedulingAvailable(summary)) {
        // The draft is retained: prepare-run rebinds the same previewed target and digests.
        throw new HttpError(409, error.code, error.detail || "busy; Replace or Run next is available");
      }
      this.drafts.delete(summary.dispatchDraftId);
      throw error;
    }
  }

  private async prepareRun(body: Record<string, unknown>): Promise<unknown> {
    const summary = this.draft(body.dispatchDraftId);
    const mode = body.mode;
    if (mode !== "replace" && mode !== "next") throw new HttpError(400, "invalid-mode");
    if (!this.options.broker.prepareRun) throw new HttpError(409, "scheduling-unavailable");
    const prepared = await this.options.broker.prepareRun(summary, mode, operatorPrompt(body.operatorPrompt));
    this.prepared.clear();
    this.prepared.set(prepared.confirmationToken, prepared);
    return {
      confirmationToken: prepared.confirmationToken,
      mode: prepared.mode,
      expiresAtUtc: prepared.expiresAtUtc,
      conflict: { kind: prepared.conflict.kind, pullRequestId: prepared.conflict.pullRequestId },
    };
  }

  private async confirmRun(body: Record<string, unknown>): Promise<unknown> {
    const token = body.confirmationToken;
    const prepared = typeof token === "string" ? this.prepared.get(token) : undefined;
    if (!prepared) throw new HttpError(404, "schedule-stale", "Prepare the run again, then confirm.");
    if (!this.options.broker.confirmRun) throw new HttpError(409, "scheduling-unavailable");
    this.prepared.delete(prepared.confirmationToken);
    const queued = await this.options.broker.confirmRun(prepared);
    this.queued.set(queued.queueId, {
      queueId: queued.queueId, mode: queued.mode, role: prepared.role, pullRequestId: prepared.pullRequestId,
      progress: null, dispatchId: null, cancelled: false,
    });
    for (const [draftId, summary] of this.drafts) {
      if (summary.repositoryIdentity.key === prepared.repositoryKey && summary.role === prepared.role &&
          summary.prSnapshot.pullRequestId === prepared.pullRequestId) this.drafts.delete(draftId);
    }
    return { queueId: queued.queueId, mode: queued.mode };
  }

  private async cancelQueued(body: Record<string, unknown>): Promise<unknown> {
    const queueId = body.queueId;
    const item = typeof queueId === "string" ? this.queued.get(queueId) : undefined;
    if (!item) throw new HttpError(404, "unknown-queue");
    if (!this.options.broker.cancelQueued) throw new HttpError(409, "scheduling-unavailable");
    await this.options.broker.cancelQueued(item.queueId);
    item.cancelled = true;
    return { queueId: item.queueId, cancelled: true };
  }

  private async cancel(body: Record<string, unknown>): Promise<unknown> {
    const dispatchId = body.dispatchId;
    const run = typeof dispatchId === "string" ? this.runs.get(dispatchId) : undefined;
    // Only runs this bridge started; TUI-owned runs stay under the TUI's control.
    if (!run) throw new HttpError(404, "unknown-run");
    if (run.terminal) return this.runView(run, this.now());
    run.cancelling = true;
    try {
      this.onTerminal(await this.options.broker.cancel(run.accepted.dispatchId));
    } finally {
      run.cancelling = false;
    }
    return this.runView(run, this.now());
  }

  private draft(value: unknown): CapabilitySummary {
    const summary = typeof value === "string" ? this.drafts.get(value) : undefined;
    if (!summary) throw new HttpError(404, "unknown-draft", "Preview the pull request again.");
    return summary;
  }

  private track(accepted: DispatchAccepted): void {
    this.options.reducer.registerLocalStream({
      eventLogPath: accepted.eventLogPath, processId: accepted.childProcessId, role: accepted.role,
      dispatch: { dispatchId: accepted.dispatchId, repositoryKey: accepted.repositoryIdentity.key, pullRequestId: accepted.pullRequestId },
    });
    this.options.tailer.registerEventLogPath(accepted.eventLogPath);
    this.runs.set(accepted.dispatchId, { accepted, startedMs: this.now(), terminal: null, terminalMs: null, cancelling: false });
    for (const [id, run] of this.runs) {
      if (this.runs.size <= MAX_RUNS) break;
      if (run.terminal) this.runs.delete(id);
    }
  }

  private onTerminal(event: DispatchTerminal): void {
    const run = this.runs.get(event.dispatchId);
    if (!run || run.terminal) return;
    run.terminal = event;
    run.terminalMs = this.now();
  }

  private onSchedule(event: RunProgress): void {
    const item = this.queued.get(event.queueId);
    if (item) item.progress = event;
  }

  private onScheduledAccepted(event: ScheduledDispatchAccepted): void {
    const item = this.queued.get(event.queueId);
    if (!item || item.dispatchId) return;
    item.dispatchId = event.dispatchId;
    this.track(event);
  }

  private runView(run: BridgeRun, now: number): unknown {
    const { accepted } = run;
    const state = this.options.reducer.getDispatch(accepted.dispatchId, accepted.repositoryIdentity.key,
      accepted.role, accepted.pullRequestId, accepted.childProcessId, now);
    const progress = manualProgress(state, run.terminal, run.startedMs, run.terminalMs, now, run.cancelling, "");
    return {
      dispatchId: accepted.dispatchId,
      role: accepted.role,
      pullRequestId: accepted.pullRequestId,
      repository: accepted.repositoryIdentity.slug,
      childProcessId: accepted.childProcessId,
      queueId: accepted.queueId ?? null,
      terminal: run.terminal?.operation ?? null,
      exitCode: run.terminal?.exitCode ?? null,
      instanceKey: state?.key ?? null,
      ...progress,
    };
  }
}

function schedulingAvailable(summary: CapabilitySummary): boolean {
  return summary.scheduling?.version === 1 && summary.scheduling.scope === "current-launcher";
}

function operatorPrompt(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") throw new HttpError(400, "invalid-prompt");
  const normalized = value.replace(/\r\n?/g, "\n");
  if (Array.from(normalized).length > MAX_PROMPT_SCALARS ||
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u.test(normalized)) {
    throw new HttpError(400, "invalid-prompt", "Instructions must be at most 512 characters without control characters.");
  }
  return normalized;
}

function instanceView(state: InstanceState, now: number): unknown {
  return {
    key: state.key,
    agent: state.agent,
    instanceId: state.instanceId,
    processId: state.processId,
    status: state.status,
    sessionNamespace: state.sessionNamespace,
    repository: state.repository,
    phase: state.phase,
    phaseElapsedMilliseconds: liveElapsedMilliseconds(state, now),
    totalElapsedMilliseconds: totalElapsedMilliseconds(state, now),
    heartbeatAgeMilliseconds: state.lastHeartbeatMs ? Math.max(0, now - state.lastHeartbeatMs) : null,
    lastEventMs: state.lastEventMs,
    pullRequestId: state.pullRequestId,
    pullRequestTitle: state.pullRequestTitle,
    pullRequestAuthor: state.pullRequestAuthor,
    pullRequestUrl: state.pullRequestUrl,
    sourceBranch: state.sourceBranch,
    targetBranch: state.targetBranch,
    sourceCommit: state.sourceCommit,
    threadCount: state.threadCount,
    actionableThreadCount: state.actionableThreadCount,
    changedFileCount: state.changedFileCount,
    candidateStory: state.candidateStory,
    modelActivity: state.modelActivity,
    blocked: state.blocked,
    waiting: state.waiting,
    completion: state.completion,
    timeline: state.timeline.slice(-TIMELINE_ITEMS).map((event) => ({
      timestampMs: event.timestampMs, eventType: event.eventType, level: event.level, text: eventNarrative(event),
    })),
  };
}

function writeDiscoveryFile(path: string, discovery: CanvasBridgeDiscovery): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(discovery)}\n`, { encoding: "utf8", mode: 0o600 });
  if (process.platform !== "win32") chmodSync(temporary, 0o600);
  renameSync(temporary, path);
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(payload);
}

async function readJsonBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  const type = req.headers["content-type"] ?? "";
  if (!/^application\/json(\s*;|$)/i.test(type)) throw new HttpError(415, "json-required");
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const buffer = chunk as Buffer;
    total += buffer.length;
    if (total > MAX_BODY_BYTES) throw new HttpError(413, "body-too-large");
    chunks.push(buffer);
  }
  let parsed: unknown;
  try {
    parsed = total ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
  } catch {
    throw new HttpError(400, "invalid-json");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new HttpError(400, "invalid-json");
  return parsed as Record<string, unknown>;
}
