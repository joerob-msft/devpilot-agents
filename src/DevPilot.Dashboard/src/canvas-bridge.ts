import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, closeSync, fstatSync, mkdirSync, openSync, readFileSync, readSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
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
import { AGENTS, type AgentRole, type InstanceState } from "./domain.js";
import { eventNarrative } from "./format.js";
import type { AgentHealthProjection } from "./health.js";
import type { PullRequestHistoryEntry, PullRequestHistoryProjection } from "./history.js";
import { isHistoryKey, type HistoryHideStorage } from "./history-hides.js";
import { manualProgress } from "./manual-progress.js";
import { isHistorical, liveElapsedMilliseconds, totalElapsedMilliseconds, type OperationsReducer } from "./reducer.js";
import type { EventTailer } from "./tailer.js";

// Opt-in loopback bridge that lets the Copilot app canvas (src/DevPilot.CopilotCanvas) observe this
// dashboard and stage manual runs through the dashboard's own trusted broker client. The broker,
// its launch provenance and the descriptor are untouched: the bridge is just another in-process
// caller of DispatchClient. It deliberately exposes no widening, narrowing, kill-switch or shutdown.
// It is owner-agnostic (no renderer dependency): the headless Golden owner (dashboard --headless,
// started from the canvas) hosts it too, and only that owner exposes POST /v1/shutdown.
export const CANVAS_BRIDGE_SCHEMA_VERSION = 1;
const MAX_BODY_BYTES = 16 * 1024;
const MAX_PROMPT_SCALARS = 512;
const MAX_DRAFTS = 8;
const MAX_RUNS = 20;
const TIMELINE_ITEMS = 15;
const AUTOMATION_CACHE_MS = 2_000;
const BUSY_CODES = new Set(["already-running", "state-contended"]);
const HISTORY_ROWS = 200;
const RECENT_PULL_REQUESTS = 8;
export const FAILURE_LOG_MAX_BYTES = 64 * 1024;
export const SKIPPED_PRS_FILE = "skipped-prs.json";
export const SKIPPED_PRS_LIMIT = 200;
const REPOSITORY_KEY = /^v1:[a-z]+:[A-Za-z0-9._:-]{1,200}$/;
const SOURCE_COMMIT = /^[0-9a-f]{40}$/;

type BridgeReducer = Pick<OperationsReducer, "list" | "getDispatch" | "registerLocalStream">;
type BridgeHealth = Pick<AgentHealthProjection, "all" | "notification" | "failureLogSource" | "skipTarget">;
type BridgeHistory = Pick<PullRequestHistoryProjection,
  "list" | "hide" | "restore" | "restoreAll" | "clearView" | "hiddenCount" | "hiddenKeyList" | "clearedThrough">;
// Canvas views. "current" is accepted from older installed canvases and served as "live".
export type CanvasView = "live" | "history";

export function canvasView(value: string | null): CanvasView {
  return value === "history" ? "history" : "live";
}

export interface CanvasBridgeOptions {
  discoveryFile: string;
  consumerRepositoryRoot: string;
  launchMode: string;
  broker: DispatchBroker;
  reducer: BridgeReducer;
  tailer: Pick<EventTailer, "registerEventLogPath">;
  // Per-PR history (the terminal History view's projection) and its persisted hide preferences.
  history?: BridgeHistory | undefined;
  historyHides?: HistoryHideStorage | undefined;
  // Error surfacing (agent.health, notification health, failure logs, operator skip).
  health?: BridgeHealth | undefined;
  // Watch state roots the dashboard tails (--state-dir). Failure logs and skip files must live inside one.
  stateRoots?: string[] | undefined;
  now?: () => number;
  token?: string;
  // Headless owner only: the canvas's explicit Stop. A terminal-owned dashboard never sets this.
  onShutdown?: (() => void) | undefined;
  // The toolkit release this dashboard runs from, shown in the canvas header.
  toolkit?: ToolkitIdentity | undefined;
}

export interface ToolkitIdentity {
  version: string;
  // Only when the install path is a pinned ~/.devpilot/toolkits/<40-hex> checkout; else "".
  commit: string;
  root: string;
}

const TOOLKIT_COMMIT_DIRECTORY = /^[0-9a-f]{40}$/i;

// Walks up from the running dashboard to the toolkit root (the directory holding VERSION).
export function toolkitIdentity(fromDirectory: string, version: string): ToolkitIdentity {
  let directory = resolve(fromDirectory);
  for (let depth = 0; depth < 8; depth += 1) {
    try {
      if (statSync(join(directory, "VERSION")).isFile()) {
        const name = directory.split(/[\\/]/).filter(Boolean).pop() ?? "";
        return { version, commit: TOOLKIT_COMMIT_DIRECTORY.test(name) ? name.toLowerCase() : "", root: directory };
      }
    } catch {
      // Not the toolkit root; keep walking.
    }
    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  return { version, commit: "", root: "" };
}

export interface CanvasBridgeDiscovery {
  schemaVersion: 1;
  url: string;
  token: string;
  dashboardPid: number;
  consumerRepositoryRoot: string;
  launchMode: string;
  headless: boolean;
  startedAtUtc: string;
  toolkitVersion: string;
  toolkitCommit: string;
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
  // Set when the broker retired the queued turn ("resumed") before any dispatch was accepted.
  retiredMs: number | null;
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
      headless: Boolean(this.options.onShutdown),
      startedAtUtc: new Date(this.now()).toISOString(),
      toolkitVersion: this.options.toolkit?.version ?? "",
      toolkitCommit: this.options.toolkit?.commit ?? "",
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
      case "POST /v1/history/hide": return this.hideHistory(body);
      case "POST /v1/history/restore": return this.restoreHistory(body);
      case "POST /v1/history/clear": return this.clearHistory();
      case "POST /v1/agents/failure-log": return this.failureLog(body);
      case "POST /v1/agents/skip": return this.skip(body);
      case "POST /v1/shutdown": return this.shutdown();
      default: throw new HttpError(404, "not-found");
    }
  }

  private async status(viewParameter: string | null): Promise<unknown> {
    const view = canvasView(viewParameter);
    const now = this.now();
    const all = this.options.reducer.list(now, undefined, undefined);
    // Live is every non-terminal instance, including stale ones (status "stale"), so nothing falls
    // between Live and History.
    const instances = all.filter((state) => view === "history" ? isHistorical(state) : !isHistorical(state));
    const history = this.options.history;
    const pullRequests = history?.list() ?? [];
    return {
      schemaVersion: CANVAS_BRIDGE_SCHEMA_VERSION,
      launchMode: this.options.launchMode,
      headless: Boolean(this.options.onShutdown),
      consumerRepositoryRoot: this.options.consumerRepositoryRoot,
      dashboardPid: process.pid,
      toolkitVersion: this.options.toolkit?.version ?? "",
      toolkitCommit: this.options.toolkit?.commit ?? "",
      toolkitRoot: this.options.toolkit?.root ?? "",
      view,
      views: ["live", "history"],
      automation: await this.automationStatus(now),
      health: this.healthView(),
      instances: instances.map((state) => instanceView(state, now)),
      historyAvailable: Boolean(history),
      ...(view === "history" ? {
        pullRequests: pullRequests.slice(0, HISTORY_ROWS).map(historyView),
        hiddenPullRequestCount: history?.hiddenCount() ?? 0,
      } : {}),
      recentPullRequests: pullRequests.slice(0, RECENT_PULL_REQUESTS).map((entry) => ({
        pullRequestId: entry.pullRequestId, title: entry.title, repository: entry.repositoryIdentity.slug,
      })),
      runs: [...this.runs.values()].map((run) => this.runView(run, now)),
      queued: [...this.queued.values()].filter((item) => !item.dispatchId && !item.cancelled && item.retiredMs === null)
        .map((item) => ({ queueId: item.queueId, mode: item.mode, role: item.role, pullRequestId: item.pullRequestId,
          state: item.progress?.state ?? "queued", code: item.progress?.code ?? "" })),
      notRun: [...this.queued.values()].filter((item) => item.retiredMs !== null)
        .map((item) => ({ queueId: item.queueId, mode: item.mode, role: item.role, pullRequestId: item.pullRequestId,
          retiredAtUtc: new Date(item.retiredMs!).toISOString() })),
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

  private healthView(): unknown {
    const health = this.options.health;
    if (!health) return null;
    return health.all().map((item) => ({ ...item, notifications: health.notification(item.role) }));
  }

  private failureLog(body: Record<string, unknown>): unknown {
    const health = this.options.health;
    const path = body.path;
    if (typeof path !== "string" || !path || path.length > 1024 || !isAbsolute(path)) throw new HttpError(400, "invalid-path");
    if (!health || health.failureLogSource(path) === undefined) throw new HttpError(404, "unknown-failure-log");
    const real = this.containedPath(path);
    if (!real) throw new HttpError(403, "outside-state-root");
    const fd = openSync(real, "r");
    try {
      const stat = fstatSync(fd);
      if (!stat.isFile()) throw new HttpError(404, "unknown-failure-log");
      const length = Math.min(stat.size, FAILURE_LOG_MAX_BYTES);
      const buffer = Buffer.alloc(length);
      readSync(fd, buffer, 0, length, stat.size - length);
      return { path, size: stat.size, truncated: stat.size > length, content: sanitizeLog(buffer.toString("utf8")) };
    } finally {
      closeSync(fd);
    }
  }

  private skip(body: Record<string, unknown>): unknown {
    const role = body.role;
    const pullRequestId = body.pullRequestId;
    if (Object.keys(body).some((key) => key !== "role" && key !== "pullRequestId")) throw new HttpError(400, "unexpected-field");
    if (typeof role !== "string" || !(AGENTS as readonly string[]).includes(role)) throw new HttpError(400, "invalid-role");
    if (!isPullRequestId(pullRequestId)) throw new HttpError(400, "invalid-pull-request-id");
    const agentRole = role as AgentRole;
    // Repository and commit come only from recorded agent events, never from the client.
    const target = this.options.health?.skipTarget(agentRole, pullRequestId);
    if (!target) throw new HttpError(404, "unknown-pull-request", "No recorded attempt for this pull request.");
    const sourceCommit = target.sourceCommit.toLowerCase();
    if (!REPOSITORY_KEY.test(target.repositoryKey) || !SOURCE_COMMIT.test(sourceCommit)) {
      throw new HttpError(409, "skip-target-incomplete", "The recorded repository or commit is not verified.");
    }
    const root = target.source ? this.stateRootOf(target.source) : undefined;
    if (!root) throw new HttpError(409, "state-root-unknown", "The agent's watch state directory is not known.");
    const roleDirectory = join(root, agentRole);
    try {
      if (!statSync(roleDirectory).isDirectory()) throw new Error("not a directory");
    } catch {
      throw new HttpError(409, "state-root-unknown", "The agent's state directory does not exist.");
    }
    const file = join(roleDirectory, SKIPPED_PRS_FILE);
    const entry = { repositoryKey: target.repositoryKey, pullRequestId, sourceCommit, skippedAtUtc: new Date(this.now()).toISOString() };
    const entries = readSkipEntries(file)
      .filter((item) => !(item.repositoryKey === entry.repositoryKey && item.pullRequestId === pullRequestId));
    entries.push(entry);
    writePrivateJson(file, { schemaVersion: 1, entries: entries.slice(-SKIPPED_PRS_LIMIT) });
    return { skipped: true, role: agentRole, pullRequestId, sourceCommit, skippedAtUtc: entry.skippedAtUtc };
  }

  private realRoots(): string[] {
    const roots: string[] = [];
    for (const root of this.options.stateRoots ?? []) {
      try { roots.push(realpathSync(resolve(root))); } catch { /* missing roots contain nothing */ }
    }
    return roots;
  }

  // Real path of `path` when it resolves (symlinks included) inside a watch state root. The lexical
  // check runs first so UNC/device paths or paths outside every root are never touched on disk.
  private containedPath(path: string): string | undefined {
    if (!this.lexicallyContained(path)) return undefined;
    let real: string;
    try { real = realpathSync(path); } catch { return undefined; }
    return this.realRoots().some((root) => isInside(root, real)) ? real : undefined;
  }

  private stateRootOf(source: string): string | undefined {
    if (!this.lexicallyContained(source)) return undefined;
    let real: string;
    try { real = realpathSync(source); } catch { return undefined; }
    return this.realRoots().find((root) => isInside(root, real));
  }

  private lexicallyContained(path: string): boolean {
    if (typeof path !== "string" || !isAbsolute(path) || /^[\\/]{2}/.test(path)) return false;
    const lexical = resolve(path);
    return (this.options.stateRoots ?? []).some((root) => !/^[\\/]{2}/.test(root) && isInside(resolve(root), lexical));
  }

  private historyOrThrow(): BridgeHistory {
    if (!this.options.history) throw new HttpError(409, "history-unavailable");
    return this.options.history;
  }

  private async persistHistory(history: BridgeHistory): Promise<void> {
    await this.options.historyHides?.save({ hiddenKeys: history.hiddenKeyList(), clearedThroughMs: history.clearedThrough() });
  }

  private async hideHistory(body: Record<string, unknown>): Promise<unknown> {
    const history = this.historyOrThrow();
    if (!isHistoryKey(body.key)) throw new HttpError(400, "invalid-history-key");
    if (!history.hide(body.key)) throw new HttpError(404, "unknown-history-key");
    await this.persistHistory(history);
    return { hidden: true, hiddenPullRequestCount: history.hiddenCount() };
  }

  private async restoreHistory(body: Record<string, unknown>): Promise<unknown> {
    const history = this.historyOrThrow();
    let restored: number;
    if (body.key === undefined) {
      restored = history.restoreAll();
    } else {
      if (!isHistoryKey(body.key)) throw new HttpError(400, "invalid-history-key");
      restored = history.restore(body.key) ? 1 : 0;
    }
    await this.persistHistory(history);
    return { restored, hiddenPullRequestCount: history.hiddenCount() };
  }

  private async clearHistory(): Promise<unknown> {
    const history = this.historyOrThrow();
    const hidden = history.clearView(this.now());
    await this.persistHistory(history);
    return { hidden, hiddenPullRequestCount: history.hiddenCount() };
  }

  private shutdown(): unknown {
    const onShutdown = this.options.onShutdown;
    if (!onShutdown) throw new HttpError(404, "not-found");
    // Let this response flush before the owner tears the bridge and broker down.
    setTimeout(onShutdown, 50);
    return { stopping: true };
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
      progress: null, dispatchId: null, cancelled: false, retiredMs: null,
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
    if (!item) return;
    item.progress = event;
    // "resumed" retires the turn; a queued run that never got a dispatch did not run.
    if (event.state === "resumed" && !item.dispatchId && item.retiredMs === null) {
      item.retiredMs = this.now();
      this.pruneQueued();
    }
  }

  private pruneQueued(): void {
    const finished = [...this.queued.values()].filter((item) => item.retiredMs !== null || item.cancelled || item.dispatchId);
    for (const item of finished.slice(0, Math.max(0, finished.length - MAX_RUNS))) this.queued.delete(item.queueId);
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

function historyView(entry: PullRequestHistoryEntry): unknown {
  const role = (agent: AgentRole) => {
    const outcome = entry.outcomes[agent];
    const activity = entry.activities[agent];
    return outcome || activity ? {
      result: outcome?.result ?? "", resultAtMs: outcome?.timestampMs ?? null,
      failureDetail: outcome?.failureDetail ?? "", failureLogPath: outcome?.failureLogPath ?? "", failureKind: outcome?.failureKind ?? "",
      status: activity?.status ?? "", statusAtMs: activity?.timestampMs ?? null,
    } : null;
  };
  return {
    key: entry.key,
    pullRequestId: entry.pullRequestId,
    title: entry.title,
    author: entry.author,
    url: entry.url,
    repository: entry.repositoryIdentity.slug,
    sourceBranch: entry.sourceBranch,
    targetBranch: entry.targetBranch,
    lastSeenMs: entry.lastSeenTimestampMs,
    reviewer: role("reviewer"),
    reviewHandler: role("review-handler"),
  };
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

function isInside(root: string, candidate: string): boolean {
  const fold = (value: string) => process.platform === "win32" ? value.toLowerCase() : value;
  const rel = relative(fold(root), fold(candidate));
  return Boolean(rel) && !rel.startsWith("..") && !isAbsolute(rel);
}

// Lines that may carry credentials: auth headers, token/password/secret assignments, GitHub tokens,
// credentialed URLs, JWTs, and SAS signatures. Kept identical to AgentHealth.ps1's pattern.
const SECRET_LINE = /Bearer |Authorization|token\s*[=:]|"token"|password\s*[=:]|passwd|secret\s*[=:]|api[_-]?key\s*[=:]|\bpat\s*[=:]|\bgh[pousr]_[A-Za-z0-9]{10,}|github_pat_|x-access-token|:\/\/[^\s\/@:]+:[^\s\/@]+@|\beyJ[A-Za-z0-9_-]{10,}\.|[?&]sig=/i;

export function sanitizeLog(text: string): string {
  return text
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .split(/\r?\n/)
    .map((line) => SECRET_LINE.test(line) ? "[line redacted: may contain a credential]" : line)
    .join("\n");
}

interface SkipEntry { repositoryKey: string; pullRequestId: number; sourceCommit: string; skippedAtUtc: string }

function readSkipEntries(file: string): SkipEntry[] {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8")) as { schemaVersion?: unknown; entries?: unknown };
    if (parsed?.schemaVersion !== 1 || !Array.isArray(parsed.entries)) return [];
    return parsed.entries.filter((item): item is SkipEntry => Boolean(item) && typeof item === "object" &&
      typeof item.repositoryKey === "string" && REPOSITORY_KEY.test(item.repositoryKey) &&
      isPullRequestId(item.pullRequestId) && typeof item.sourceCommit === "string" && SOURCE_COMMIT.test(item.sourceCommit) &&
      typeof item.skippedAtUtc === "string" && Number.isFinite(Date.parse(item.skippedAtUtc)));
  } catch {
    return [];
  }
}

function writePrivateJson(path: string, value: unknown): void {
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", mode: 0o600, flag: "wx" });
    if (process.platform !== "win32") chmodSync(temporary, 0o600);
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
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
