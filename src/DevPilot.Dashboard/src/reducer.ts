import {
  boundedText,
  eventKey,
  getBoolean,
  getNumber,
  getString,
  getStringArray,
  getStringList,
  type AgentEvent,
  type AgentRole,
  type InstanceState,
  type InstanceStatus,
  type SourceDiagnostic,
} from "./domain.js";

export const TIMELINE_LIMIT = 500;
export const DIAGNOSTIC_LIMIT = 20;
export const CYCLE_LIMIT = 20;
export const STALE_AFTER_MS = 20_000;

const STATUS_ORDER: Record<InstanceStatus, number> = {
  failed: 0,
  blocked: 1,
  running: 2,
  stale: 2,
  waiting: 3,
  completed: 4,
};

function statusOrder(state: InstanceState): number {
  if (state.lifecycle === "stopped" || state.status === "completed") {
    return state.status === "failed" ? 5 : 6;
  }
  return STATUS_ORDER[state.status];
}

function boundedCount(data: Record<string, unknown>, key: string): number {
  return Math.min(1_000_000, Math.max(0, Math.floor(getNumber(data, key))));
}

function isResolvedCompletion(result: string): boolean {
  return ["completed", "delivered", "handled", "passed", "previewed", "promoted", "reviewed", "succeeded", "success"].includes(
    result.trim().toLowerCase(),
  );
}

function newState(event: AgentEvent): InstanceState {
  return {
    key: eventKey(event),
    agent: event.agent,
    instanceId: event.instanceId,
    processId: event.processId,
    schemaVersion: event.schemaVersion,
    repository: "",
    organization: "",
    project: "",
    target: "",
    operator: "",
    capabilities: [],
    writes: "",
    vote: "",
    phase: "starting",
    phaseElapsedMilliseconds: 0,
    phaseTimestampMs: event.timestampMs,
    cycleNumber: event.cycleNumber,
    pullRequestId: event.pullRequestId,
    pullRequestTitle: "",
    pullRequestAuthor: "",
    pullRequestUrl: "",
    sourceBranch: "",
    targetBranch: "",
    threadCount: 0,
    actionableThreadCount: 0,
    changedFileCount: 0,
    sourceCommit: event.sourceCommit,
    candidates: { scanned: 0, selected: 0, skipped: 0 },
    candidateStory: "Waiting for candidate scan",
    blocked: null,
    retryable: false,
    outstanding: [],
    completion: null,
    waiting: null,
    lifecycle: "starting",
    currentRunStartedMs: event.timestampMs,
    modelActivity: "Not started",
    lastEventMs: event.timestampMs,
    lastHeartbeatMs: event.timestampMs,
    lastSequence: 0,
    gapCount: 0,
    duplicateCount: 0,
    status: "running",
    timeline: [],
    cycles: [],
    sourceDiagnostics: [],
    sources: [],
  };
}

function skippedTotal(value: unknown): number {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return 0;
  return Object.values(value as Record<string, unknown>).reduce<number>(
    (sum, item) => sum + (typeof item === "number" && Number.isFinite(item) ? item : 0),
    0,
  );
}

function findingCount(data: Record<string, unknown>, severity: string): number {
  const direct = getNumber(data, severity) || getNumber(data, `${severity}Count`);
  if (direct) return direct;
  const findings = data.findings;
  return findings !== null && typeof findings === "object" && !Array.isArray(findings)
    ? getNumber(findings as Record<string, unknown>, severity)
    : 0;
}

function addBounded<T>(items: T[], item: T, limit: number): T[] {
  const next = [...items, item];
  return next.length > limit ? next.slice(next.length - limit) : next;
}

function calculateStatus(state: InstanceState, now: number): InstanceStatus {
  if (state.completion?.result === "failed" || state.timeline.at(-1)?.eventType === "cycle.failed") return "failed";
  if (state.blocked) return "blocked";
  if (state.lifecycle !== "stopped" && now - state.lastHeartbeatMs > STALE_AFTER_MS) return "stale";
  if (state.waiting) return "waiting";
  if (state.lifecycle === "stopped" || state.completion) return "completed";
  return "running";
}

export function liveElapsedMilliseconds(state: InstanceState, now = Date.now()): number {
  if (!state.phaseTimestampMs) return state.phaseElapsedMilliseconds;
  if (state.status === "running" || state.status === "stale") {
    return Math.max(0, state.phaseElapsedMilliseconds + now - state.phaseTimestampMs);
  }
  return state.phaseElapsedMilliseconds;
}

export function totalElapsedMilliseconds(state: InstanceState, now = Date.now()): number {
  if (state.completion?.elapsedMilliseconds) return state.completion.elapsedMilliseconds;
  const end = state.lifecycle === "stopped" ? state.lastEventMs : now;
  return Math.max(0, end - state.currentRunStartedMs);
}

export class OperationsReducer {
  private readonly states = new Map<string, InstanceState>();
  private readonly sourceKeys = new Map<string, Set<string>>();
  private readonly pendingSourceDiagnostics = new Map<string, SourceDiagnostic[]>();
  private readonly diagnostics: SourceDiagnostic[] = [];

  apply(event: AgentEvent, source = ""): boolean {
    const key = eventKey(event);
    const state = this.states.get(key) ?? newState(event);
    if (event.sequence <= state.lastSequence) {
      state.duplicateCount++;
      this.states.set(key, state);
      return false;
    }
    if (state.lastSequence > 0 && event.sequence > state.lastSequence + 1) {
      const missing = event.sequence - state.lastSequence - 1;
      state.gapCount += missing;
      this.addDiagnosticToState(state, {
        source,
        kind: "sequence-gap",
        message: `missing ${missing} event(s): expected ${state.lastSequence + 1}, received ${event.sequence}`,
        timestampMs: event.timestampMs,
      });
    }
    state.lastSequence = event.sequence;
    state.lastEventMs = Math.max(state.lastEventMs, event.timestampMs);
    if (event.eventType === "agent.heartbeat") state.lastHeartbeatMs = event.timestampMs;
    state.processId = event.processId || state.processId;
    state.schemaVersion = event.schemaVersion;
    state.cycleNumber = event.cycleNumber || state.cycleNumber;
    state.pullRequestId = event.pullRequestId || state.pullRequestId;
    state.sourceCommit = event.sourceCommit || state.sourceCommit;
    if (event.eventType !== "agent.heartbeat") {
      state.timeline = addBounded(state.timeline, event, TIMELINE_LIMIT);
    }
    if (source && !state.sources.includes(source)) state.sources = addBounded(state.sources, source, 10);
    if (source) {
      const keys = this.sourceKeys.get(source) ?? new Set<string>();
      keys.add(key);
      this.sourceKeys.set(source, keys);
      const pending = this.pendingSourceDiagnostics.get(source);
      if (pending) {
        for (const diagnostic of pending) this.addDiagnosticToState(state, diagnostic);
        this.pendingSourceDiagnostics.delete(source);
      }
    }

    this.reduceEvent(state, event);
    state.status = calculateStatus(state, event.timestampMs);
    this.states.set(key, state);
    return true;
  }

  private reduceEvent(state: InstanceState, event: AgentEvent): void {
    const data = event.data;
    switch (event.eventType) {
      case "agent.started":
        state.lifecycle = "active";
        state.repository = getString(data, "repository");
        state.organization = getString(data, "organization");
        state.project = getString(data, "project");
        state.target = getString(data, "target");
        state.operator = getString(data, "operator");
        state.writes = getString(data, "writes");
        state.vote = getString(data, "vote");
        state.capabilities = getStringArray(data, "capabilities");
        if (!state.capabilities.length) {
          state.capabilities = state.writes
            .split(",")
            .map((item) => item.trim())
            .filter(Boolean)
            .slice(0, 20);
          if (state.vote === "on") state.capabilities.push("vote");
        }
        state.lastHeartbeatMs = event.timestampMs;
        state.waiting = null;
        break;
      case "agent.stopped":
        state.lifecycle = "stopped";
        state.waiting = null;
        break;
      case "cycle.started":
        state.lifecycle = "active";
        state.currentRunStartedMs = event.timestampMs;
        state.phase = "starting cycle";
        state.phaseElapsedMilliseconds = 0;
        state.phaseTimestampMs = event.timestampMs;
        state.modelActivity = "Preparing review";
        state.candidates = { scanned: 0, selected: 0, skipped: 0 };
        state.candidateStory = "Scanning candidates";
        state.pullRequestId = 0;
        state.pullRequestTitle = "";
        state.pullRequestAuthor = "";
        state.pullRequestUrl = "";
        state.sourceBranch = "";
        state.targetBranch = "";
        state.threadCount = 0;
        state.actionableThreadCount = 0;
        state.changedFileCount = 0;
        state.sourceCommit = "";
        state.waiting = null;
        state.completion = null;
        state.blocked = null;
        state.retryable = false;
        state.outstanding = [];
        break;
      case "phase.changed":
        state.phase = getString(data, "phase") || event.message || state.phase;
        state.phaseElapsedMilliseconds = Math.max(0, getNumber(data, "elapsedMilliseconds"));
        state.phaseTimestampMs = event.timestampMs;
        state.waiting = null;
        state.modelActivity = /model|prompt|inference|review/i.test(state.phase)
          ? `Active: ${state.phase}`
          : `Last phase: ${state.phase}`;
        break;
      case "candidate.selected":
        this.reducePullRequestContext(state, data);
        state.candidateStory = state.pullRequestId
          ? `Selected PR #${state.pullRequestId} after scanning ${state.candidates.scanned || "available"} candidate(s)`
          : "Candidate selected";
        break;
      case "candidates.enumerated":
        state.candidates = {
          scanned: getNumber(data, "scanned"),
          selected: getNumber(data, "selected"),
          skipped: skippedTotal(data.skipped),
        };
        state.candidateStory = state.candidates.selected
          ? `Scanned ${state.candidates.scanned}; selected ${state.candidates.selected}; skipped ${state.candidates.skipped}`
          : `Scanned ${state.candidates.scanned}; none selected; skipped ${state.candidates.skipped}`;
        break;
      case "reviewer.started":
        this.reducePullRequestContext(state, data);
        state.modelActivity = "Review started";
        break;
      case "delivery.retrying":
        state.retryable = true;
        state.outstanding = getStringArray(data, "outstanding");
        break;
      case "delivery.blocked":
        state.blocked = {
          reason: getString(data, "reason") || event.message,
          outstanding: getStringArray(data, "outstanding"),
          retryable: getBoolean(data, "retryable"),
          nextRetry: getString(data, "nextRetry"),
          timestampMs: event.timestampMs,
        };
        state.retryable = state.blocked.retryable;
        state.outstanding = state.blocked.outstanding;
        break;
      case "review.completed":
      case "work.completed": {
        this.reducePullRequestContext(state, data);
        const result = getString(data, "result") || "completed";
        state.completion = {
          result,
          requested: getStringList(data, "requested"),
          delivered: getStringList(data, "delivered"),
          reason: getString(data, "reason"),
          findings: {
            critical: findingCount(data, "critical"),
            important: findingCount(data, "important"),
            suggestion: findingCount(data, "suggestion"),
          },
          summary: getString(data, "summary"),
          previewArtifact: getString(data, "previewArtifact"),
          nextScan: getString(data, "nextScan") || getString(data, "nextRetry"),
          elapsedMilliseconds: Math.max(0, getNumber(data, "elapsedMilliseconds")),
          timestampMs: event.timestampMs,
        };
        state.modelActivity = `Completed: ${result}`;
        if (isResolvedCompletion(result)) {
          state.blocked = null;
          state.retryable = false;
          state.outstanding = [];
        }
        break;
      }
      case "cycle.completed":
      case "cycle.failed": {
        const result = event.eventType === "cycle.failed" ? "failed" : getString(data, "result") || "completed";
        state.cycles = addBounded(
          state.cycles,
          {
            cycleNumber: event.cycleNumber,
            result,
            scanned: state.candidates.scanned,
            selected: state.candidates.selected,
            blocked: getNumber(data, "blockedCount") || (state.blocked ? 1 : 0),
            retried: getNumber(data, "retryCount"),
            timestampMs: event.timestampMs,
          },
          CYCLE_LIMIT,
        );
        if (event.eventType === "cycle.failed") {
          state.completion = {
            result: "failed",
            requested: [],
            delivered: [],
            reason: getString(data, "reason") || event.message,
            findings: { critical: 0, important: 0, suggestion: 0 },
            summary: "",
            previewArtifact: "",
            nextScan: "",
            elapsedMilliseconds: Math.max(0, event.timestampMs - state.currentRunStartedMs),
            timestampMs: event.timestampMs,
          };
        }
        break;
      }
      case "agent.waiting":
        state.waiting = {
          kind: getString(data, "kind") || "cycle",
          delayMilliseconds: Math.max(0, getNumber(data, "delayMilliseconds")),
          sinceMs: event.timestampMs,
        };
        break;
    }
  }

  private reducePullRequestContext(state: InstanceState, data: Record<string, unknown>): void {
    state.pullRequestId = Math.max(state.pullRequestId, getNumber(data, "pullRequestId"), getNumber(data, "id"));
    state.pullRequestTitle = getString(data, "title") || state.pullRequestTitle;
    state.pullRequestAuthor = getString(data, "author") || state.pullRequestAuthor;
    state.pullRequestUrl = getString(data, "url") || state.pullRequestUrl;
    state.sourceBranch = getString(data, "sourceBranch") || state.sourceBranch;
    state.targetBranch = getString(data, "targetBranch") || state.targetBranch;
    if (Object.hasOwn(data, "threadCount")) state.threadCount = boundedCount(data, "threadCount");
    if (Object.hasOwn(data, "actionableThreadCount")) {
      state.actionableThreadCount = boundedCount(data, "actionableThreadCount");
    }
    if (Object.hasOwn(data, "changedFileCount")) {
      state.changedFileCount = boundedCount(data, "changedFileCount");
    }
  }

  addSourceDiagnostic(diagnostic: SourceDiagnostic): void {
    const bounded = { ...diagnostic, message: boundedText(diagnostic.message, 240) };
    const previous = this.diagnostics.at(-1);
    if (!previous || previous.source !== bounded.source || previous.kind !== bounded.kind || previous.message !== bounded.message) {
      this.diagnostics.push(bounded);
      if (this.diagnostics.length > DIAGNOSTIC_LIMIT) this.diagnostics.splice(0, this.diagnostics.length - DIAGNOSTIC_LIMIT);
    }
    const keys = this.sourceKeys.get(diagnostic.source);
    if (!keys) {
      const pending = this.pendingSourceDiagnostics.get(diagnostic.source) ?? [];
      this.pendingSourceDiagnostics.set(
        diagnostic.source,
        addBounded(pending, diagnostic, DIAGNOSTIC_LIMIT),
      );
      return;
    }
    for (const key of keys) {
      const state = this.states.get(key);
      if (state) this.addDiagnosticToState(state, diagnostic);
    }
  }

  private addDiagnosticToState(state: InstanceState, diagnostic: SourceDiagnostic): void {
    state.sourceDiagnostics = addBounded(
      state.sourceDiagnostics,
      { ...diagnostic, message: boundedText(diagnostic.message, 240) },
      DIAGNOSTIC_LIMIT,
    );
  }

  list(now = Date.now(), role?: AgentRole): InstanceState[] {
    const items = [...this.states.values()].filter((state) => !role || state.agent === role);
    for (const state of items) state.status = calculateStatus(state, now);
    return items.sort(
      (a, b) =>
        statusOrder(a) - statusOrder(b) ||
        b.lastEventMs - a.lastEventMs ||
        a.key.localeCompare(b.key),
    );
  }

  get(key: string, now = Date.now()): InstanceState | undefined {
    const state = this.states.get(key);
    if (state) state.status = calculateStatus(state, now);
    return state;
  }

  counts(now = Date.now()): Record<InstanceStatus, number> {
    const result: Record<InstanceStatus, number> = {
      failed: 0,
      blocked: 0,
      running: 0,
      stale: 0,
      waiting: 0,
      completed: 0,
    };
    for (const state of this.list(now)) result[state.status]++;
    return result;
  }

  globalDiagnostics(): SourceDiagnostic[] {
    return [...this.diagnostics];
  }
}
