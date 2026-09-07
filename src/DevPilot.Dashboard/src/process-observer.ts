import type { AgentRole } from "./domain.js";

export interface LocalProcessStream {
  eventLogPath: string;
  processId: number;
  role: AgentRole;
  dispatch?: { dispatchId: string; repositoryKey: string; pullRequestId: number };
}

export type ProcessPresence = "present" | "absent" | "unknown";
export type ProcessObserver = (processId: number) => Promise<ProcessPresence>;

export const observeProcess: ProcessObserver = async (processId) => {
  if (!Number.isSafeInteger(processId) || processId <= 0 || processId > 2_147_483_647) return "unknown";
  try {
    // Signal 0 only checks existence; it neither delivers a signal nor establishes instance
    // identity. In particular, a reused PID must never be treated as this agent being alive.
    process.kill(processId, 0);
    return "present";
  } catch (error) {
    // Access denied and unsupported observations are not evidence of exit.
    return (error as NodeJS.ErrnoException)?.code === "ESRCH" ? "absent" : "unknown";
  }
};
