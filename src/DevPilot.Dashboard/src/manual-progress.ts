import { boundedText, type InstanceState } from "./domain.js";
import type { DispatchTerminal } from "./dispatch.js";
import { duration, eventNarrative } from "./format.js";
import { STALE_AFTER_MS } from "./reducer.js";

export interface ManualProgress {
  headline: string;
  detail: string;
  latest: string;
  elapsed: string;
  attention: boolean;
}

export function manualProgress(
  state: InstanceState | undefined,
  terminal: DispatchTerminal | null,
  startedMs: number,
  terminalMs: number | null,
  now: number,
  cancelling: boolean,
  monitorError: string,
): ManualProgress {
  const stopped = Boolean(terminal || state?.lifecycle === "stopped" || state?.exitObservedMs != null);
  const completion = state?.completion;
  const result = completion?.result.trim().toLowerCase() ?? "";
  const latestEvent = state?.timeline.at(-1);
  const progress: ManualProgress = {
    headline: "STARTED / RUNNING",
    detail: state ? `Phase: ${state.phase}` : "Waiting for first progress; no agent events received yet.",
    latest: latestEvent ? eventNarrative(latestEvent) : "",
    elapsed: duration(Math.max(0, (terminalMs ?? (stopped ? state?.lastEventMs : now) ?? now) - startedMs)),
    attention: false,
  };
  if (terminal?.operation === "cancelled") {
    progress.headline = "CANCELLED";
    progress.detail = terminal.result === "cancelled-forced"
      ? "Forced cancellation; the broker observed process-tree exit."
      : "Cancellation completed; the broker observed child exit.";
  } else if (terminal && terminal.exitCode !== 0) {
    progress.headline = "FAILED";
    progress.detail = `Child exited with code ${terminal.exitCode ?? "unknown"}.`;
    progress.attention = true;
  } else if (!terminal && monitorError) {
    progress.headline = "STATUS UNKNOWN";
    progress.detail = "Lost broker contact; child exit is not confirmed.";
    progress.latest = monitorError;
    progress.attention = true;
  } else if (cancelling && !terminal) {
    progress.headline = "CANCELLING...";
    progress.detail = "Waiting for broker-confirmed child exit.";
  } else if (result === "failed" || state?.status === "failed") {
    progress.headline = "FAILED";
    progress.detail = completion?.reason || "Agent reported a failure.";
    progress.attention = true;
  } else if (state?.blocked || /blocked|partial|pending|concurrent/.test(result)) {
    progress.headline = "BLOCKED";
    progress.detail = state?.blocked?.reason || completion?.reason || `Work result: ${result}`;
    progress.attention = true;
  } else if (stopped) {
    progress.headline = result === "cancelled" ? "CANCELLED" : completion || terminal ? "FINISHED" : "EXITED / OUTCOME UNKNOWN";
    progress.detail = completion
      ? `Work result: ${completion.result}${completion.reason ? ` — ${completion.reason}` : ""}`
      : "Child exited; review outcome was not reported.";
    progress.attention = !completion;
  } else if ((!state && now - startedMs >= 30_000) ||
      (state && now - state.lastHeartbeatMs > STALE_AFTER_MS)) {
    progress.headline = "STARTED / PROGRESS UNKNOWN";
    progress.detail = state ? "Heartbeat overdue; last known progress shown below." : "No progress after 30s; monitoring is still retrying.";
    progress.attention = true;
  } else if (completion) {
    progress.detail = `Work result: ${completion.result}; waiting for child exit.`;
  }
  if (completion?.summary && !monitorError) progress.latest = completion.summary;
  return { ...progress, detail: boundedText(progress.detail, 240), latest: boundedText(progress.latest, 240) };
}
