export interface Agent {
  id: string;
  prompt: string;
  inputProfile: string;
  timeoutSeconds: number;
  schedule: { enabled: boolean; everyMinutes: number };
}
export interface Swarm {
  id: string;
  workers: string[];
  synthesisPrompt: string;
}
export interface Manifest {
  schemaVersion: 1;
  inputProfiles: Record<string, { files: string[] }>;
  agents: Agent[];
  swarms: Swarm[];
}
export interface Packet {
  revision: string;
  inputHash: string;
  files: { path: string; sha256: string; content: string }[];
}
export interface Prepared {
  agentId: string;
  prompt: string;
  promptHash: string;
  timeoutSeconds: number;
  packet: Packet;
}
export type Status = "queued" | "running" | "succeeded" | "failed" |
  "cancelled" | "timed_out" | "invalid_result" | "interrupted" | "unknown" | "blocked";
export const terminal = (status: Status) => status !== "queued" && status !== "running";
export interface Finding {
  title: string;
  evidence: string;
  recommendation: string;
}
export interface Result {
  schemaVersion: 1;
  nonce: string;
  inputHash: string;
  summary: string;
  findings: Finding[];
}
export interface Attempt {
  id: string;
  runId: string;
  agentId: string;
  kind: "agent" | "worker" | "synthesis";
  status: Status;
  createdAt: string;
  startedAt?: string;
  endedAt?: string;
  cancelRequested?: boolean;
  nonce: string;
  prepared: Prepared;
  result?: Result;
  error?: string;
  model?: string;
  transportNote?: string;
}
export interface SwarmRun {
  id: string;
  recipeId: string;
  requestId: string;
  workers: string[];
  synthesis: Prepared;
  synthesisId?: string;
  status: Status;
  createdAt: string;
  cancelRequested?: boolean;
}
export interface Schedule {
  enabled: boolean;
  nextAt: number;
  everyMinutes: number;
}
export interface State {
  schemaVersion: 1;
  repository: string;
  attempts: Attempt[];
  swarms: SwarmRun[];
  requests: Record<string, { target: string; runId: string }>;
  schedules: Record<string, Schedule>;
}
export interface ExecutionOutcome {
  status: Status;
  result?: Result;
  error?: string;
  model?: string;
  transportNote?: string;
}
export interface Execution {
  done: Promise<ExecutionOutcome>;
  cancel(): void;
}
export type Executor = (attempt: Attempt, directory: string) => Execution;
