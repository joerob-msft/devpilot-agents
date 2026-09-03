import {
  boundedText,
  getString,
  type AgentEvent,
  type AgentRole,
  type RepositoryIdentityV1,
} from "./domain.js";

export const PR_HISTORY_LIMIT = 5_000;

export interface PullRequestRoleOutcome {
  role: AgentRole;
  result: string;
  timestampMs: number;
  instanceId: string;
  sequence: number;
}

export interface PullRequestHistoryEntry {
  key: string;
  repositoryIdentity: RepositoryIdentityV1;
  pullRequestId: number;
  title: string;
  author: string;
  url: string;
  sourceBranch: string;
  targetBranch: string;
  sourceCommit: string;
  lastSeenTimestampMs: number;
  lastInstanceId: string;
  lastSequence: number;
  outcomes: Partial<Record<AgentRole, PullRequestRoleOutcome>>;
}

function canonicalPrKey(identity: RepositoryIdentityV1, pullRequestId: number): string {
  return `${identity.key}:pr:${pullRequestId}`;
}

function orderOf(event: Pick<AgentEvent, "timestampMs" | "instanceId" | "sequence">): [number, string, number] {
  return [event.timestampMs, event.instanceId, event.sequence];
}

function compareOrder(
  left: [number, string, number],
  right: [number, string, number],
): number {
  return left[0] - right[0] || compareOrdinal(left[1], right[1]) || left[2] - right[2];
}

function compareOrdinal(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function terminalResult(event: AgentEvent): string {
  if (event.eventType === "cycle.failed") return getString(event.data, "reason") || "failed";
  if (event.eventType === "work.completed" || event.eventType === "review.completed") {
    return getString(event.data, "result") || "completed";
  }
  return "";
}

export class PullRequestHistoryProjection {
  private readonly entries = new Map<string, PullRequestHistoryEntry>();
  private readonly hiddenKeys = new Set<string>();
  private evictionDiagnostic = "";

  constructor(private readonly limit = PR_HISTORY_LIMIT) {
    if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("history limit must be positive");
  }

  apply(event: AgentEvent): boolean {
    const identity = event.repositoryIdentity;
    if (event.schemaVersion !== 3 || !identity?.verified || !identity.dispatchEligible || event.pullRequestId <= 0) {
      return false;
    }
    const key = canonicalPrKey(identity, event.pullRequestId);
    const current = this.entries.get(key);
    const eventOrder = orderOf(event);
    const currentOrder: [number, string, number] = current
      ? [current.lastSeenTimestampMs, current.lastInstanceId, current.lastSequence]
      : [-1, "", -1];
    const newer = compareOrder(eventOrder, currentOrder) > 0;
    const data = event.data;
    const next: PullRequestHistoryEntry = current ?? {
      key,
      repositoryIdentity: identity,
      pullRequestId: event.pullRequestId,
      title: "",
      author: "",
      url: "",
      sourceBranch: "",
      targetBranch: "",
      sourceCommit: "",
      lastSeenTimestampMs: event.timestampMs,
      lastInstanceId: event.instanceId,
      lastSequence: event.sequence,
      outcomes: {},
    };
    if (newer) {
      next.repositoryIdentity = identity;
      next.title = getString(data, "title") || next.title;
      next.author = getString(data, "author") || next.author;
      next.url = getString(data, "url") || next.url;
      next.sourceBranch = getString(data, "sourceBranch") || next.sourceBranch;
      next.targetBranch = getString(data, "targetBranch") || next.targetBranch;
      next.sourceCommit = event.sourceCommit || next.sourceCommit;
      next.lastSeenTimestampMs = event.timestampMs;
      next.lastInstanceId = event.instanceId;
      next.lastSequence = event.sequence;
    }
    const result = terminalResult(event);
    const priorOutcome = next.outcomes[event.agent];
    if (result && (!priorOutcome ||
      compareOrder(eventOrder, [priorOutcome.timestampMs, priorOutcome.instanceId, priorOutcome.sequence]) > 0)) {
      next.outcomes = {
        ...next.outcomes,
        [event.agent]: {
          role: event.agent,
          result: boundedText(result, 160),
          timestampMs: event.timestampMs,
          instanceId: event.instanceId,
          sequence: event.sequence,
        },
      };
    }
    this.entries.set(key, next);
    this.evict();
    return newer || Boolean(result);
  }

  list(filter = "", repositoryKey = ""): PullRequestHistoryEntry[] {
    const needle = filter.trim().toLowerCase();
    return [...this.entries.values()]
      .filter((entry) => !this.hiddenKeys.has(entry.key))
      .filter((entry) => !repositoryKey || entry.repositoryIdentity.key === repositoryKey)
      .filter((entry) => this.matchesFilter(entry, needle))
      .sort((left, right) =>
        right.lastSeenTimestampMs - left.lastSeenTimestampMs || compareOrdinal(left.key, right.key));
  }

  matches(pullRequestId: number, filter = ""): PullRequestHistoryEntry[] {
    if (!Number.isSafeInteger(pullRequestId) || pullRequestId <= 0) return [];
    const needle = filter.trim().toLowerCase();
    return [...this.entries.values()]
      .filter((entry) => entry.pullRequestId === pullRequestId)
      .filter((entry) => this.matchesFilter(entry, needle))
      .sort((left, right) =>
        right.lastSeenTimestampMs - left.lastSeenTimestampMs || compareOrdinal(left.key, right.key));
  }

  jump(pullRequestId: number, repositoryKey = ""): PullRequestHistoryEntry | null {
    if (!Number.isSafeInteger(pullRequestId) || pullRequestId <= 0) return null;
    const matches = [...this.entries.values()].filter((entry) =>
      entry.pullRequestId === pullRequestId &&
      (!repositoryKey || entry.repositoryIdentity.key === repositoryKey));
    if (matches.length !== 1) return null;
    this.hiddenKeys.delete(matches[0]!.key);
    return matches[0]!;
  }

  hide(key: string): boolean {
    if (!this.entries.has(key)) return false;
    this.hiddenKeys.add(key);
    return true;
  }

  restore(key: string): boolean {
    return this.hiddenKeys.delete(key);
  }

  restoreAll(): number {
    const restored = this.hiddenKeys.size;
    this.hiddenKeys.clear();
    return restored;
  }

  hideAll(): number {
    let hidden = 0;
    for (const key of this.entries.keys()) {
      if (!this.hiddenKeys.has(key)) {
        this.hiddenKeys.add(key);
        hidden++;
      }
    }
    return hidden;
  }

  diagnostic(): string {
    return this.evictionDiagnostic;
  }

  private matchesFilter(entry: PullRequestHistoryEntry, needle: string): boolean {
    if (!needle) return true;
    const outcomes = Object.values(entry.outcomes).map((item) => item?.result ?? "").join(" ");
    return [
      String(entry.pullRequestId),
      entry.title,
      entry.author,
      entry.repositoryIdentity.repositoryName,
      entry.repositoryIdentity.slug,
      outcomes,
    ].some((value) => value.toLowerCase().includes(needle));
  }

  private evict(): void {
    if (this.entries.size <= this.limit) return;
    const ordered = [...this.entries.values()].sort((left, right) =>
      left.lastSeenTimestampMs - right.lastSeenTimestampMs || compareOrdinal(left.key, right.key));
    const removeCount = this.entries.size - this.limit;
    for (const entry of ordered.slice(0, removeCount)) {
      this.entries.delete(entry.key);
      this.hiddenKeys.delete(entry.key);
    }
    if (!this.evictionDiagnostic) {
      this.evictionDiagnostic = boundedText(
        `PR history exceeded ${this.limit} entries; ${removeCount} oldest entr${removeCount === 1 ? "y was" : "ies were"} evicted.`,
        240,
      );
    }
  }
}
