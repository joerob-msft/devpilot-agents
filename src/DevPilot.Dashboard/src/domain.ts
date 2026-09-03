export const AGENTS = ["reviewer", "review-handler"] as const;
export type AgentRole = (typeof AGENTS)[number];
export type EventLevel = "debug" | "info" | "warning" | "error";

export interface RepositoryIdentityV1 {
  schemaVersion: 1;
  provider: "AzureDevOps" | "GitHub";
  repositoryId: string;
  organization: string;
  project: string;
  repositoryName: string;
  slug: string;
  key: string;
  verifiedAtUtc: string;
  verified: boolean;
  dispatchEligible: boolean;
}

export interface AgentDispatchV1 {
  schemaVersion: 1;
  dispatchId: string;
  ownership: "tui";
  forceAnalysis: true;
}

export interface AgentEvent {
  schemaVersion: number;
  agent: AgentRole;
  instanceId: string;
  processId: number;
  timestamp: string;
  timestampMs: number;
  sequence: number;
  eventType: string;
  level: EventLevel;
  cycleNumber: number;
  pullRequestId: number;
  sourceCommit: string;
  repositoryIdentity: RepositoryIdentityV1 | null;
  dispatch: AgentDispatchV1 | null;
  data: Record<string, unknown>;
  message: string;
}

export interface SourceDiagnostic {
  source: string;
  kind: "malformed" | "sequence-gap" | "io";
  message: string;
  timestampMs: number;
}

export type InstanceStatus =
  | "failed"
  | "blocked"
  | "running"
  | "waiting"
  | "completed"
  | "stale";

export type ViewFilter = "live" | "current" | "history";

export interface Completion {
  result: string;
  requested: string[];
  delivered: string[];
  reason: string;
  findings: { critical: number; important: number; suggestion: number };
  summary: string;
  previewArtifact: string;
  nextScan: string;
  elapsedMilliseconds: number;
  timestampMs: number;
}

export interface BlockedWarning {
  reason: string;
  outstanding: string[];
  retryable: boolean;
  nextRetry: string;
  timestampMs: number;
}

export interface CycleSummary {
  cycleNumber: number;
  result: string;
  scanned: number;
  selected: number;
  blocked: number;
  retried: number;
  timestampMs: number;
}

export interface InstanceState {
  key: string;
  agent: AgentRole;
  instanceId: string;
  processId: number;
  schemaVersion: number;
  repository: string;
  organization: string;
  project: string;
  target: string;
  operator: string;
  capabilities: string[];
  writes: string;
  vote: string;
  phase: string;
  phaseElapsedMilliseconds: number;
  phaseTimestampMs: number;
  cycleNumber: number;
  pullRequestId: number;
  pullRequestTitle: string;
  pullRequestAuthor: string;
  pullRequestUrl: string;
  sourceBranch: string;
  targetBranch: string;
  threadCount: number;
  actionableThreadCount: number;
  changedFileCount: number;
  sourceCommit: string;
  candidates: { scanned: number; selected: number; skipped: number };
  candidateStory: string;
  blocked: BlockedWarning | null;
  retryable: boolean;
  outstanding: string[];
  completion: Completion | null;
  waiting: { kind: string; delayMilliseconds: number; sinceMs: number } | null;
  lifecycle: "starting" | "active" | "stopped";
  currentRunStartedMs: number;
  modelActivity: string;
  lastEventMs: number;
  lastHeartbeatMs: number;
  lastSequence: number;
  gapCount: number;
  duplicateCount: number;
  status: InstanceStatus;
  timeline: AgentEvent[];
  cycles: CycleSummary[];
  sourceDiagnostics: SourceDiagnostic[];
  sources: string[];
  sessionNamespace: string;
}

const MAX_TEXT = 512;
const MAX_DATA_KEYS = 50;

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function finiteInteger(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : fallback;
}

function boundedString(value: unknown, fallback = ""): string {
  return typeof value === "string"
    ? value.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim().slice(0, MAX_TEXT)
    : fallback;
}

function boundedData(value: unknown): Record<string, unknown> {
  const source = asRecord(value);
  const result: Record<string, unknown> = {};
  for (const key of Object.keys(source).slice(0, MAX_DATA_KEYS)) {
    result[key.slice(0, 80)] = boundedUnknown(source[key], 1);
  }
  return result;
}

function boundedUnknown(value: unknown, depth: number): unknown {
  if (value === null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") return value.slice(0, MAX_TEXT);
  if (depth >= 4) return "[TRUNCATED]";
  if (Array.isArray(value)) return value.slice(0, 50).map((item) => boundedUnknown(item, depth + 1));
  if (typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value).slice(0, MAX_DATA_KEYS)) {
      result[key.slice(0, 80)] = boundedUnknown(item, depth + 1);
    }
    return result;
  }
  return String(value).slice(0, MAX_TEXT);
}

function parseRepositoryIdentity(value: unknown, required: boolean): RepositoryIdentityV1 | null {
  if (value === null || value === undefined) {
    if (required) throw new Error("repositoryIdentity is required for schema v3");
    return null;
  }
  const raw = asRecord(value);
  const provider = raw.provider;
  if (provider !== "AzureDevOps" && provider !== "GitHub") throw new Error("repositoryIdentity.provider is invalid");
  const repositoryId = boundedString(raw.repositoryId);
  const organization = boundedString(raw.organization);
  const project = boundedString(raw.project);
  const repositoryName = boundedString(raw.repositoryName);
  const slug = boundedString(raw.slug);
  const key = boundedString(raw.key);
  const verified = raw.verified === true;
  const dispatchEligible = raw.dispatchEligible === true;
  const verifiedAtUtc = boundedString(raw.verifiedAtUtc);
  if (!organization || !repositoryName || !slug) throw new Error("repositoryIdentity display scope is incomplete");
  if (verified) {
    if (!repositoryId || !key || !verifiedAtUtc || !Number.isFinite(Date.parse(verifiedAtUtc))) {
      throw new Error("verified repositoryIdentity is incomplete");
    }
    const expectedKey = `v1:${provider.toLowerCase()}:${repositoryId}`;
    if (key !== expectedKey) throw new Error("repositoryIdentity.key does not match provider and repositoryId");
    if (provider === "AzureDevOps" && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(repositoryId)) {
      throw new Error("AzureDevOps repositoryIdentity.repositoryId must be a normalized GUID");
    }
    if (provider === "GitHub" && !/^[1-9][0-9]*$/.test(repositoryId)) {
      throw new Error("GitHub repositoryIdentity.repositoryId must be an opaque decimal string");
    }
  } else if (repositoryId || key || verifiedAtUtc || dispatchEligible) {
    throw new Error("unverified repositoryIdentity cannot be dispatch eligible or carry canonical identity");
  }
  if (dispatchEligible !== verified) throw new Error("dispatch eligibility requires provider verification");
  return {
    schemaVersion: 1,
    provider,
    repositoryId,
    organization,
    project,
    repositoryName,
    slug,
    key,
    verifiedAtUtc,
    verified,
    dispatchEligible,
  };
}

function parseDispatch(value: unknown): AgentDispatchV1 | null {
  if (value === null || value === undefined) return null;
  const raw = asRecord(value);
  const dispatchId = boundedString(raw.dispatchId);
  if (raw.schemaVersion !== 1 || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(dispatchId) ||
      raw.ownership !== "tui" || raw.forceAnalysis !== true) {
    throw new Error("dispatch metadata is invalid");
  }
  return { schemaVersion: 1, dispatchId: dispatchId.toLowerCase(), ownership: "tui", forceAnalysis: true };
}

export function parseAgentEvent(value: unknown): AgentEvent {
  const raw = asRecord(value);
  const agent = raw.agent;
  if (agent !== "reviewer" && agent !== "review-handler") {
    throw new Error("agent must be reviewer or review-handler");
  }
  const instanceId = boundedString(raw.instanceId);
  if (!instanceId) throw new Error("instanceId is required");
  const sequence = finiteInteger(raw.sequence, -1);
  if (sequence < 0) throw new Error("sequence must be a non-negative integer");
  const eventType = boundedString(raw.eventType);
  if (!eventType) throw new Error("eventType is required");
  const timestamp = boundedString(raw.timestamp);
  const timestampMs = Date.parse(timestamp);
  if (!timestamp || !Number.isFinite(timestampMs)) throw new Error("timestamp must be ISO-8601");
  const level = raw.level;
  const normalizedLevel: EventLevel =
    level === "debug" || level === "warning" || level === "error" ? level : "info";

  const schemaVersion = Math.max(1, finiteInteger(raw.schemaVersion, 1));
  return {
    schemaVersion,
    agent,
    instanceId,
    processId: Math.max(0, finiteInteger(raw.processId)),
    timestamp,
    timestampMs,
    sequence,
    eventType,
    level: normalizedLevel,
    cycleNumber: Math.max(0, finiteInteger(raw.cycleNumber)),
    pullRequestId: Math.max(0, finiteInteger(raw.pullRequestId)),
    sourceCommit: boundedString(raw.sourceCommit),
    repositoryIdentity: parseRepositoryIdentity(raw.repositoryIdentity, schemaVersion >= 3),
    dispatch: parseDispatch(raw.dispatch),
    data: boundedData(raw.data),
    message: boundedString(raw.message),
  };
}

export function parseAgentEventLine(line: string): AgentEvent {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch (error) {
    throw new Error(`invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  return parseAgentEvent(value);
}

export function eventKey(event: Pick<AgentEvent, "agent" | "instanceId">): string {
  return `${event.agent}:${event.instanceId}`;
}

export function getString(data: Record<string, unknown>, key: string): string {
  return boundedString(data[key]);
}

export function getNumber(data: Record<string, unknown>, key: string): number {
  const value = data[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function getBoolean(data: Record<string, unknown>, key: string): boolean {
  return data[key] === true;
}

export function getStringArray(data: Record<string, unknown>, key: string): string[] {
  const value = data[key];
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string").slice(0, 20).map((item) => boundedString(item).slice(0, 120))
    : [];
}

export function getStringList(data: Record<string, unknown>, key: string): string[] {
  const values = getStringArray(data, key);
  if (values.length) return values;
  const value = getString(data, key);
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 20);
}

export function boundedText(value: unknown, max = 160): string {
  if (typeof value === "string") return boundedString(value).slice(0, max);
  try {
    return JSON.stringify(value).replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").slice(0, max);
  } catch {
    return "[unprintable]";
  }
}
