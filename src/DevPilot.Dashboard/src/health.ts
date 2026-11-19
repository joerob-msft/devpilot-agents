import { AGENTS, boundedText, failureFields, getNumber, getString, type AgentEvent, type AgentRole } from "./domain.js";

// Error-surfacing projection (contract B and F): the latest agent.health per role, a fallback derived
// from consecutive failed/deferred work.completed for agents that predate agent.health, Teams
// notification delivery health, and the failure logs / skip targets the bridge may act on. Everything
// here comes from recorded agent events; the bridge never trusts client-supplied paths or commits.
export const FAILING_THRESHOLD = 3;
export const NOTIFICATION_WARNING_THRESHOLD = 3;
const MAX_STUCK = 20;
const MAX_RECORDED = 500;
const FAILURE_RESULTS = new Set(["failed", "deferred", "error"]);
const NEUTRAL_RESULTS = new Set(["blocked"]);
const NOTIFICATION_SUCCESS = new Set(["sent", "delivered", "fallback-delivered", "posted", "replied", "updated"]);
const NOTIFICATION_FAILURE = new Set(["failed", "deferred", "queued", "error", "dropped", "rejected"]);

export type HealthState = "healthy" | "failing" | "stuck";

export interface StuckPullRequest {
  pullRequestId: number;
  sourceCommit: string;
  outcome: string;
  repeatCount: number;
  nextAttemptUtc: string | null;
}

export interface RoleHealth {
  role: AgentRole;
  state: HealthState;
  // "agent" = reported by agent.health; "derived" = fallback from work.completed; "none" = no data.
  source: "agent" | "derived" | "none";
  consecutiveFailures: number;
  failingSinceUtc: string | null;
  lastSuccessUtc: string | null;
  cause: string;
  failureKind: string;
  stuck: StuckPullRequest[];
  updatedAtMs: number | null;
}

export interface NotificationHealth {
  role: AgentRole;
  failuresSinceSuccess: number;
  latestReason: string;
  lastSuccessMs: number | null;
  lastFailureMs: number | null;
  warning: boolean;
}

export interface SkipTarget {
  repositoryKey: string;
  sourceCommit: string;
  source: string;
}

interface Derived {
  consecutive: number;
  failingSinceMs: number | null;
  lastSuccessMs: number | null;
  cause: string;
  failureKind: string;
  lastMs: number;
}

function iso(ms: number | null): string | null {
  return ms === null ? null : new Date(ms).toISOString();
}

function isoOrNull(value: unknown): string | null {
  return typeof value === "string" && Number.isFinite(Date.parse(value)) ? new Date(Date.parse(value)).toISOString() : null;
}

function boundedSet<K, V>(map: Map<K, V>, key: K, value: V): void {
  map.delete(key);
  map.set(key, value);
  while (map.size > MAX_RECORDED) map.delete(map.keys().next().value as K);
}

export function parseStuck(value: unknown): StuckPullRequest[] {
  if (!Array.isArray(value)) return [];
  const result: StuckPullRequest[] = [];
  for (const item of value.slice(0, MAX_STUCK)) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const raw = item as Record<string, unknown>;
    const pullRequestId = raw.pullRequestId;
    if (typeof pullRequestId !== "number" || !Number.isSafeInteger(pullRequestId) || pullRequestId <= 0) continue;
    const sourceCommit = typeof raw.sourceCommit === "string" ? raw.sourceCommit.slice(0, 64) : "";
    result.push({
      pullRequestId,
      sourceCommit,
      outcome: boundedText(raw.outcome ?? "", 80),
      repeatCount: Math.max(0, Math.min(1_000_000, Math.floor(getNumber(raw, "repeatCount")))),
      nextAttemptUtc: isoOrNull(raw.nextAttemptUtc),
    });
  }
  return result;
}

export class AgentHealthProjection {
  private readonly reported = new Map<AgentRole, { health: RoleHealth; timestampMs: number; source: string }>();
  private readonly derived = new Map<AgentRole, Derived>();
  private readonly notifications = new Map<AgentRole, NotificationHealth>();
  private readonly failureLogs = new Map<string, string>();
  private readonly attempts = new Map<string, SkipTarget & { timestampMs: number }>();

  apply(event: AgentEvent, source = ""): boolean {
    switch (event.eventType) {
      case "agent.health": return this.applyHealth(event, source);
      case "work.completed": return this.applyCompletion(event, source);
      case "notification.delivery": return this.applyNotification(event);
      default: return false;
    }
  }

  private applyHealth(event: AgentEvent, source: string): boolean {
    const prior = this.reported.get(event.agent);
    if (prior && prior.timestampMs > event.timestampMs) return false;
    const data = event.data;
    const rawState = getString(data, "state");
    const state: HealthState = rawState === "failing" || rawState === "stuck" ? rawState : "healthy";
    const stuck = parseStuck(data.stuck);
    this.reported.set(event.agent, {
      timestampMs: event.timestampMs,
      source,
      health: {
        role: event.agent,
        state,
        source: "agent",
        consecutiveFailures: Math.max(0, Math.floor(getNumber(data, "consecutiveFailures"))),
        failingSinceUtc: isoOrNull(data.failingSinceUtc),
        lastSuccessUtc: isoOrNull(data.lastSuccessUtc),
        cause: getString(data, "cause").slice(0, 240),
        failureKind: this.derived.get(event.agent)?.failureKind ?? "",
        stuck,
        updatedAtMs: event.timestampMs,
      },
    });
    const repositoryKey = event.repositoryIdentity?.verified ? event.repositoryIdentity.key : "";
    if (repositoryKey) {
      for (const item of stuck) {
        if (item.sourceCommit) this.recordAttempt(event.agent, item.pullRequestId, repositoryKey, item.sourceCommit, source, event.timestampMs);
      }
    }
    return true;
  }

  private applyCompletion(event: AgentEvent, source: string): boolean {
    const result = getString(event.data, "result").toLowerCase() || "completed";
    const failure = failureFields(event.data);
    if (failure.failureLogPath) boundedSet(this.failureLogs, failure.failureLogPath, source);
    const repositoryKey = event.repositoryIdentity?.verified ? event.repositoryIdentity.key : "";
    if (event.pullRequestId > 0 && repositoryKey && event.sourceCommit) {
      this.recordAttempt(event.agent, event.pullRequestId, repositoryKey, event.sourceCommit, source, event.timestampMs);
    }
    const derived = this.derived.get(event.agent) ??
      { consecutive: 0, failingSinceMs: null, lastSuccessMs: null, cause: "", failureKind: "", lastMs: 0 };
    if (event.timestampMs < derived.lastMs) return Boolean(failure.failureLogPath);
    derived.lastMs = event.timestampMs;
    if (FAILURE_RESULTS.has(result)) {
      if (derived.consecutive === 0) derived.failingSinceMs = event.timestampMs;
      derived.consecutive += 1;
      derived.cause = failure.failureDetail || getString(event.data, "reason").slice(0, 240) || result;
      derived.failureKind = failure.failureKind ?? "";
    } else if (!NEUTRAL_RESULTS.has(result)) {
      derived.consecutive = 0;
      derived.failingSinceMs = null;
      derived.lastSuccessMs = event.timestampMs;
      derived.cause = "";
      derived.failureKind = "";
    }
    this.derived.set(event.agent, derived);
    return true;
  }

  private applyNotification(event: AgentEvent): boolean {
    const outcome = getString(event.data, "outcome").toLowerCase();
    const current = this.notifications.get(event.agent) ?? {
      role: event.agent, failuresSinceSuccess: 0, latestReason: "", lastSuccessMs: null, lastFailureMs: null, warning: false,
    };
    if (NOTIFICATION_SUCCESS.has(outcome)) {
      if (current.lastSuccessMs !== null && current.lastSuccessMs > event.timestampMs) return false;
      current.lastSuccessMs = event.timestampMs;
      if (current.lastFailureMs === null || current.lastFailureMs <= event.timestampMs) {
        current.failuresSinceSuccess = 0;
        current.latestReason = "";
      }
    } else if (NOTIFICATION_FAILURE.has(outcome) || event.level === "error") {
      if (current.lastSuccessMs !== null && current.lastSuccessMs > event.timestampMs) return false;
      current.failuresSinceSuccess += 1;
      current.lastFailureMs = Math.max(current.lastFailureMs ?? 0, event.timestampMs);
      current.latestReason = (getString(event.data, "code") || getString(event.data, "reason") || outcome).slice(0, 120);
    } else {
      return false;
    }
    current.warning = current.failuresSinceSuccess >= NOTIFICATION_WARNING_THRESHOLD;
    this.notifications.set(event.agent, current);
    return true;
  }

  private recordAttempt(role: AgentRole, pullRequestId: number, repositoryKey: string, sourceCommit: string,
      source: string, timestampMs: number): void {
    const key = `${role}:${pullRequestId}`;
    const prior = this.attempts.get(key);
    if (prior && prior.timestampMs > timestampMs) return;
    boundedSet(this.attempts, key, { repositoryKey, sourceCommit, source, timestampMs });
  }

  health(role: AgentRole): RoleHealth {
    const reported = this.reported.get(role);
    if (reported) return reported.health;
    const derived = this.derived.get(role);
    if (!derived) {
      return { role, state: "healthy", source: "none", consecutiveFailures: 0, failingSinceUtc: null, lastSuccessUtc: null,
        cause: "", failureKind: "", stuck: [], updatedAtMs: null };
    }
    return {
      role,
      state: derived.consecutive >= FAILING_THRESHOLD ? "failing" : "healthy",
      source: "derived",
      consecutiveFailures: derived.consecutive,
      failingSinceUtc: iso(derived.failingSinceMs),
      lastSuccessUtc: iso(derived.lastSuccessMs),
      cause: derived.cause,
      failureKind: derived.failureKind,
      stuck: [],
      updatedAtMs: derived.lastMs || null,
    };
  }

  all(): RoleHealth[] {
    return AGENTS.map((role) => this.health(role));
  }

  notification(role: AgentRole): NotificationHealth | null {
    return this.notifications.get(role) ?? null;
  }

  // The event source that recorded this exact failure log path, if any.
  failureLogSource(path: string): string | undefined {
    return this.failureLogs.get(path);
  }

  // Server-side skip target: only a PR this role reported (stuck or attempted) with a verified
  // repository and a recorded source commit.
  skipTarget(role: AgentRole, pullRequestId: number): SkipTarget | undefined {
    const stuck = this.reported.get(role)?.health.stuck.find((item) => item.pullRequestId === pullRequestId);
    const attempt = this.attempts.get(`${role}:${pullRequestId}`);
    if (!attempt) return undefined;
    const sourceCommit = stuck?.sourceCommit || attempt.sourceCommit;
    return { repositoryKey: attempt.repositoryKey, sourceCommit, source: attempt.source };
  }
}
