import { boundedText, type AgentEvent, type InstanceState, type InstanceStatus } from "./domain.js";

export function duration(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${seconds}s`;
}

export function age(timestampMs: number, now = Date.now()): string {
  return `${duration(Math.max(0, now - timestampMs))} ago`;
}

export function shortId(instanceId: string): string {
  return instanceId.slice(0, 8);
}

export function shortCommit(commit: string): string {
  return commit ? commit.slice(0, 12) : "-";
}

export function statusColor(status: InstanceStatus): string {
  switch (status) {
    case "failed":
      return "#ff6b6b";
    case "blocked":
      return "#f0b45a";
    case "running":
      return "#61d6a7";
    case "stale":
      return "#d9a15f";
    case "waiting":
      return "#77bdfb";
    case "completed":
      return "#8a94a6";
  }
}

export function roleLabel(role: InstanceState["agent"]): string {
  return role === "review-handler" ? "HANDLER" : "REVIEWER";
}

export function eventSummary(event: AgentEvent): string {
  const pr = event.pullRequestId ? ` PR ${event.pullRequestId}` : "";
  const detail =
    event.message ||
    (typeof event.data.phase === "string" ? event.data.phase : "") ||
    (typeof event.data.result === "string" ? event.data.result : "");
  return `${event.eventType}${pr}${detail ? ` - ${boundedText(detail, 120)}` : ""}`;
}

const EVENT_NARRATIVE: Record<string, string> = {
  "agent.started": "Observer connected",
  "cycle.started": "New scan cycle started",
  "candidates.enumerated": "Candidate scan completed",
  "candidate.selected": "Pull request selected",
  "reviewer.started": "Review started",
  "review.completed": "Review completed",
  "work.completed": "Delivery completed",
  "delivery.retrying": "Delivery will retry",
  "delivery.blocked": "Delivery is blocked",
  "agent.waiting": "Waiting for next scan",
  "cycle.completed": "Scan cycle completed",
  "cycle.failed": "Scan cycle failed",
  "agent.stopped": "Observer stopped",
};

export function eventNarrative(event: AgentEvent): string {
  const label =
    event.eventType === "phase.changed"
      ? `Phase: ${typeof event.data.phase === "string" ? boundedText(event.data.phase, 80) : "changed"}`
      : EVENT_NARRATIVE[event.eventType] ?? "Agent activity";
  const detail =
    event.message ||
    (typeof event.data.reason === "string" ? event.data.reason : "") ||
    (typeof event.data.summary === "string" ? event.data.summary : "");
  return `${label}${detail ? ` - ${boundedText(detail, 100)}` : ""}`;
}

export function line(value: string, width: number): string {
  return value.length <= width ? value : `${value.slice(0, Math.max(0, width - 3))}...`;
}
