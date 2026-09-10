import { Index, Show } from "solid-js";
import type { ScrollBoxRenderable } from "@opentui/core";
import type { AgentRole, InstanceState } from "./domain.js";
import type { PullRequestHistoryEntry } from "./history.js";
import type { AutomationAgentStatus, AutomationStatus, CapabilitySummary, ResolvedManualTarget, RunPrepared, RunScheduleMode, ScanNowResult } from "./dispatch.js";
import type { ManualProgress } from "./manual-progress.js";
import type { ManualMode } from "./app.js";
import { age, duration, eventNarrative, line, shortCommit } from "./format.js";
import { liveElapsedMilliseconds } from "./reducer.js";

export interface SimpleColors {
  panel: string; panelAlt: string; border: string; accent: string;
  text: string; muted: string; warning: string; ok: string; error: string;
}

export interface SimpleRow {
  key: string;
  kind: "instance" | "pr";
  agent: string;
  pullRequestId: number;
  reference: string;
  title: string;
  status: string;
  activity: string;
  attention: boolean;
  details: string[];
}

export const simpleRole = (role: AgentRole): string => role === "reviewer" ? "Reviewer" : "Review Handler";

const compactRole = (role: AgentRole): string => role === "reviewer" ? "Reviewer" : "Handler";

function automationCadence(agent: AutomationAgentStatus): string {
  if (!agent.continuous) return "once";
  const seconds = agent.intervalSeconds;
  if (seconds === null) return "interval unavailable";
  const interval = seconds % 3600 === 0 ? `${seconds / 3600}h` : seconds % 60 === 0 ? `${seconds / 60}m` : `${seconds}s`;
  return `every ${interval}`;
}

export function automationStatusText(status: AutomationStatus): string {
  if (!status.available || status.scope !== "current-launcher") return "Auto: unavailable";
  const first = status.agents[0];
  if (!first) return "Auto: available / no workers reported";
  if (status.agents.every((agent) => automationCadence(agent) === automationCadence(first))) {
    const roles = status.agents.length === 2 ? "Both" : compactRole(first.role);
    const state = status.agents.every((agent) => agent.state === first.state) ? first.state :
      status.agents.map((agent) => `${compactRole(agent.role)} ${agent.state}`).join("; ");
    return `Auto: ${roles} / ${automationCadence(first)} / ${state}`;
  }
  return `Auto: ${status.agents.map((agent) => `${compactRole(agent.role)} ${automationCadence(agent)} ${agent.state}`).join("; ")}`;
}

export function scanNowResultText(result: ScanNowResult): string {
  const outcomes: Record<ScanNowResult["results"][number]["outcome"], string> = {
    requested: "wake requested", "already-running": "already working",
    "manual-priority": "manual priority", unavailable: "unavailable",
  };
  return result.results.length
    ? `Scan: ${result.results.map((item) => `${compactRole(item.role)} ${outcomes[item.outcome]}`).join("; ")}`
    : "Scan: no automatic workers reported.";
}

export function simpleCapability(name: string): string {
  const names: Record<string, string> = {
    EnableFindingComments: "Finding comments", EnableSummaryComment: "Summary comments",
    EnableThreadReplies: "Thread replies", EnableCodeChanges: "Code changes", EnablePush: "Code pushes",
    EnableApprovalVote: "Approval vote", EnableAutoComplete: "Auto-complete",
    EnableBuddyRequeue: "Requeue validation", LocalValidation: "Local validation",
    ResumeCodingSession: "Resume coding session", EnableTeamsNotifications: "Teams notifications",
  };
  return names[name] ?? name;
}

export function simpleInstanceRow(state: InstanceState): SimpleRow {
  const now = Date.now();
  const event = state.timeline.at(-1);
  const failure = state.blocked?.reason || (state.status === "failed" ? state.completion?.reason : "") ||
    state.sourceDiagnostics.at(-1)?.message || "";
  const outcome = state.completion?.result || (state.exitObservedMs !== null ? "Interrupted / outcome unknown" : "Not reported");
  const baseActivity = failure || (event ? eventNarrative(event) : state.modelActivity) || "No activity reported";
  const showLiveTiming = state.status === "running" || state.status === "stale";
  const phaseTiming = showLiveTiming ? duration(liveElapsedMilliseconds(state, now)) : "";
  const activity = showLiveTiming ? `${baseActivity} (${phaseTiming})` : baseActivity;
  const reference = `${event?.repositoryIdentity?.slug || state.repository || "Repository not reported"} / ${state.pullRequestId ? `PR #${state.pullRequestId}` : "No PR selected"}`;
  return {
    key: `instance:${state.key}`, kind: "instance", agent: simpleRole(state.agent), pullRequestId: state.pullRequestId, reference,
    title: state.pullRequestTitle, status: state.status === "exited" ? `Exited / ${state.completion?.result || "outcome unknown"}` : state.status,
    activity, attention: Boolean(failure) || ["failed", "blocked", "stale", "exited"].includes(state.status),
    details: [
      `${simpleRole(state.agent)} | ${reference}`,
      ...(failure ? [`Action needed: ${failure}`] : []),
      state.pullRequestTitle || "Title not reported",
      ...(state.pullRequestAuthor ? [`Author: ${state.pullRequestAuthor}`] : []),
      `Phase: ${state.phase || "Not reported"}${showLiveTiming ? ` (${phaseTiming})` : ""}`,
      ...(state.lastHeartbeatMs ? [`Heartbeat: ${age(state.lastHeartbeatMs, now)}`] : []),
      `Latest activity: ${activity}`,
      `Outcome: ${outcome}`,
      ...(state.completion?.summary ? [state.completion.summary] : []),
      ...(state.completion?.reason && state.completion.reason !== failure ? [state.completion.reason] : []),
    ],
  };
}

export function simpleHistoryRow(entry: PullRequestHistoryEntry): SimpleRow {
  const outcomes = (["reviewer", "review-handler"] as const)
    .filter((role) => entry.outcomes[role])
    .map((role) => `${simpleRole(role)}: ${entry.outcomes[role]!.result}`);
  const status = outcomes.join("; ") || "Outcome not reported";
  const reference = `${entry.repositoryIdentity.slug} / PR #${entry.pullRequestId}`;
  return {
    key: `pr:${entry.key}`, kind: "pr", pullRequestId: entry.pullRequestId,
    agent: entry.outcomes.reviewer && entry.outcomes["review-handler"] ? "Both agents" :
      entry.outcomes["review-handler"] ? "Review Handler" : entry.outcomes.reviewer ? "Reviewer" : "Agent not reported",
    reference, title: entry.title, status, activity: entry.title || "Title not reported",
    attention: /fail|block|partial|unknown|not reported/i.test(status),
    details: [
      reference, entry.title || "Title not reported", `Author: ${entry.author || "Not reported"}`,
      `Reviewer: ${entry.outcomes.reviewer?.result ?? "No reported outcome"}`,
      `Review Handler: ${entry.outcomes["review-handler"]?.result ?? "No reported outcome"}`,
      ...(entry.sourceBranch || entry.targetBranch ? [`${entry.sourceBranch || "?"} -> ${entry.targetBranch || "?"}`] : []),
      ...(entry.sourceCommit ? [`Commit: ${shortCommit(entry.sourceCommit)}`] : []),
    ],
  };
}

export function selectionWindow(index: number, capacity: number): number {
  return Math.max(0, index - Math.max(1, capacity) + 1);
}

export function SimpleView(props: {
  rows: SimpleRow[];
  selectedKey: string | null;
  detail: { key: string; reference: string } | null;
  history: boolean;
  width: number;
  height: number;
  colors: SimpleColors;
  scrollRef: (value: ScrollBoxRenderable) => void;
}) {
  const sidebar = () => props.width >= 100 && props.height >= 4;
  const listWidth = () => sidebar() ? Math.min(42, Math.floor(props.width * 0.4)) : props.width;
  const agentLabel = (row: SimpleRow) => sidebar() && row.agent === "Agent not reported" ? "Unknown agent" : row.agent;
  const selectedIndex = () => Math.max(0, props.rows.findIndex((row) => row.key === props.selectedKey));
  const selection = () => props.rows[selectedIndex()];
  const capacity = () => Math.max(1, Math.floor((props.height - 2) / 2));
  const start = () => selectionWindow(selectedIndex(), capacity());
  const detail = () => props.rows.find((row) => row.key === props.detail?.key);
  return (
    <box flexDirection="row" flexGrow={1} minWidth={0} minHeight={0} gap={sidebar() ? 1 : 0} overflow="hidden">
      <Show when={sidebar() || !props.detail}>
        <box id={sidebar() ? "simple-agent-sidebar" : "simple-agent-list"}
          border borderColor={sidebar() ? props.detail ? props.colors.muted : props.colors.accent : props.colors.border}
          backgroundColor={props.colors.panel} title={` ${props.history ? "HISTORY" : "LIVE AGENTS"} `}
          width={sidebar() ? listWidth() : "100%"} flexGrow={sidebar() ? 0 : 1} flexShrink={0}
          flexDirection="column" minHeight={0} paddingX={1} overflow="hidden">
          <Show when={props.rows.length} fallback={
            <text fg={props.colors.muted} wrapMode="word">{props.history ? "No retained history." : "No live agents. Previous outcomes are in History."}</text>
          }>
            <Index each={props.rows.slice(start(), start() + capacity())}>
              {(row: () => SimpleRow) => (
                <box height={2} flexShrink={0} flexDirection="column"
                  backgroundColor={row().key === props.selectedKey ? props.colors.panelAlt : props.colors.panel}>
                  <text height={1} fg={row().attention ? props.colors.warning : props.colors.accent}>
                    {line(`${row().key === props.selectedKey ? "> " : "  "}${agentLabel(row())} | ${row().pullRequestId ? `PR #${row().pullRequestId}` : "No PR selected"}${
                      sidebar() ? "" : ` | ${row().status}`}`, listWidth() - 6)}
                  </text>
                  <text height={1} fg={row().attention ? props.colors.warning : props.colors.text}>
                    {line(`  ${sidebar() ? row().status : row().activity}`, listWidth() - 6)}
                  </text>
                </box>
              )}
            </Index>
          </Show>
        </box>
      </Show>
      <Show when={sidebar() || props.detail}>
        <box id="simple-main-content" border
          borderColor={sidebar() ? props.detail ? props.colors.accent : props.colors.muted : props.colors.border}
          backgroundColor={props.colors.panel} title={props.detail ? " DETAILS " : " SELECTION - Enter details "}
          flexDirection="column" flexGrow={1} minWidth={0} minHeight={0} paddingX={1} overflow="hidden">
          <Show when={props.detail} fallback={
            <Show when={selection()} fallback={<text wrapMode="word" fg={props.colors.muted}>Select an agent or retained PR to see its latest activity.</text>}>
              {(row: () => SimpleRow) => (
                <box flexDirection="column" flexGrow={1} minHeight={0} overflow="hidden">
                  <text flexShrink={0} wrapMode="word" fg={props.colors.accent}>{row().reference}</text>
                  <text flexShrink={0} wrapMode="word" fg={row().attention ? props.colors.warning : props.colors.text}>{row().status}</text>
                  <Show when={row().title}><text flexShrink={0} wrapMode="word" fg={props.colors.text}>{row().title}</text></Show>
                  <Show when={row().activity !== row().title}>
                    <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>{row().activity}</text>
                  </Show>
                </box>
              )}
            </Show>
          }>
            <scrollbox id="simple-detail-scroll" ref={props.scrollRef} flexGrow={1} minHeight={0} scrollY>
              <Show when={detail()} fallback={
                <>
                  <text flexShrink={0} wrapMode="word" fg={props.colors.accent}>{props.detail?.reference}</text>
                  <text flexShrink={0} wrapMode="word" fg={props.colors.warning}>
                    {props.history ? "Selected history is no longer available." : "Selected agent is no longer live in this view."}
                  </text>
                  <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Esc returns to the list. No other item has been substituted.</text>
                </>
              }>
                {(row: () => SimpleRow) => (
                  <>
                    <text flexShrink={0} wrapMode="word" fg={row().attention ? props.colors.warning : props.colors.accent}>{row().status}</text>
                    <Index each={row().details}>
                      {(text) => <text flexShrink={0} wrapMode="word" fg={props.colors.text}>{text()}</text>}
                    </Index>
                  </>
                )}
              </Show>
            </scrollbox>
          </Show>
        </box>
      </Show>
    </box>
  );
}

export function SimpleManualPanel(props: {
  mode: ManualMode; role: AgentRole; targetInput: string; target: ResolvedManualTarget | null;
  summary: CapabilitySummary | null; prompt: string; accepted: boolean;
  status: string; progress: ManualProgress | null; startUncertain: boolean;
  colors: SimpleColors; scrollRef: (value: ScrollBoxRenderable) => void;
  advanced?: boolean; processId?: number | undefined;
  scheduling?: {
    headline: string; choosing: boolean; choice: RunScheduleMode | "back";
    prepared: RunPrepared | null; automationNote: string; attention: boolean;
  } | undefined;
}) {
  const target = () => props.summary ?? props.target;
  const headline = () => {
    if (props.progress) {
      if (props.progress.headline === "STARTED / RUNNING") return "STARTED";
      if (props.progress.headline === "FINISHED" && props.progress.attention) return "FINISHED / OUTCOME UNKNOWN";
      return props.progress.headline;
    }
    if (props.scheduling?.headline) return props.scheduling.headline;
    if (props.mode === "dispatching") return props.startUncertain ? "START STATUS UNKNOWN" : "STARTING";
    if (props.mode === "terminal") return "NOT STARTED / REQUEST FAILED";
    if (props.mode === "confirm" || props.mode === "confirm-final") return "NOT STARTED / READY TO START";
    return "NOT STARTED";
  };
  return (
    <box title=" START AGENT BY PR ID " border borderColor={props.colors.warning}
      backgroundColor={props.colors.panel} flexDirection="column" flexGrow={1} minHeight={0} paddingX={1} overflow="hidden">
      <text height={1} flexShrink={0} fg={props.progress?.attention || props.startUncertain || props.mode === "terminal"
        ? props.colors.warning : props.colors.accent}>{headline()}</text>
      <scrollbox ref={props.scrollRef} flexGrow={1} minHeight={0} scrollY>
        <Show when={props.scheduling?.choosing}>
          <Index each={["replace", "next", "back"] as const}>
            {(choice) => (
              <text id={`busy-choice-${choice()}`} height={1} flexShrink={0}
                fg={choice() === props.scheduling?.choice ? props.colors.accent : props.colors.text}>
                {choice() === props.scheduling?.choice ? "> " : "  "}
                {choice() === "replace" ? "Replace / run now" : choice() === "next" ? "Run next" : "Back"}
              </text>
            )}
          </Index>
        </Show>
        <Show when={props.status}><text flexShrink={0} wrapMode="word" fg={props.colors.warning}>{props.status}</text></Show>
        <Show when={props.scheduling?.prepared}>
          {(prepared: () => RunPrepared) => (
            <>
              <text flexShrink={0} wrapMode="word" fg={props.colors.warning}>
                Current {prepared().conflict.kind === "automatic" ? "automatic" : "manual"} {simpleRole(prepared().role)}: PR #{prepared().conflict.pullRequestId}
              </text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.text}>
                {prepared().mode === "replace"
                  ? "Replace requests cancellation of this exact current-launcher work, then runs your PR after authority is released."
                  : "Run next waits for this current PR, not the whole scan cycle, then gives your PR a turn."}
              </text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.warning}>Completed comments and pushes are not undone.</text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>
                Current launcher only. Automatic work resumes after manual completion. The queue ends with this Watch session.
              </text>
            </>
          )}
        </Show>
        <Show when={props.scheduling?.automationNote}>
          <text flexShrink={0} wrapMode="word" fg={props.scheduling?.attention ? props.colors.warning : props.colors.muted}>{props.scheduling?.automationNote}</text>
        </Show>
        <Show when={props.mode === "target" || props.mode === "resolving"}>
          <text flexShrink={0} wrapMode="word" fg={props.colors.text}>PR ID: {props.targetInput || "(blank)"}</text>
          <text flexShrink={0} wrapMode="word" fg={props.colors.text}>Agent: {simpleRole(props.role)}</text>
          <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Uses the selected agent's configured repository.</text>
        </Show>
        <Show when={props.mode === "resolving"}>
          <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Resolving repository and PR...</text>
        </Show>
        <Show when={target()}>
          {(value: () => ResolvedManualTarget) => (
            <>
              <text flexShrink={0} wrapMode="word" fg={props.colors.accent}>{value().repositoryIdentity.slug} / PR #{value().prSnapshot.pullRequestId}</text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.text}>Agent: {simpleRole(props.role)}</text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.text}>{value().prSnapshot.title || "Title not reported"}</text>
            </>
          )}
        </Show>
        <Show when={props.mode === "prompt"}>
          <text flexShrink={0} wrapMode="word" fg={props.colors.text}>Optional instructions ({Array.from(props.prompt).length}/512 characters)</text>
          <text flexShrink={0} wrapMode="word" fg={props.colors.text}>{props.prompt || "(none)"}</text>
        </Show>
        <Show when={props.mode === "describing"}>
          <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Preparing preview...</text>
        </Show>
        <Show when={!props.accepted && props.mode !== "prompt" && props.summary}>
          {(summary: () => CapabilitySummary) => (
            <>
              <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Commit: {shortCommit(summary().prSnapshot.sourceCommit)}</text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.text}>Allowed actions:</text>
              <Index each={summary().capabilities} fallback={<text fg={props.colors.ok} flexShrink={0}>No PR mutations allowed.</text>}>
                {(name) => <text flexShrink={0} wrapMode="word" fg={props.colors.text}>- {simpleCapability(name())}</text>}
              </Index>
              <Index each={summary().dynamicConstraints}>
                {(constraint) => <text flexShrink={0} wrapMode="word" fg={props.colors.warning}>Constraint: {constraint()}</text>}
              </Index>
              <Show when={props.advanced}>
                <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>
                  Not allowed: {summary().mandatoryDenies.map(simpleCapability).join(", ") || "none reported"}
                </text>
              </Show>
              <Show when={props.prompt}><text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Instructions: {props.prompt}</text></Show>
            </>
          )}
        </Show>
        <Show when={props.progress}>
          {(progress: () => ManualProgress) => (
            <>
              <text flexShrink={0} wrapMode="word" fg={props.colors.text}>Elapsed: {progress().elapsed}</text>
              <Show when={props.advanced && props.processId}>
                <text flexShrink={0} wrapMode="word" fg={props.colors.muted}>Child PID {props.processId}</text>
              </Show>
              <text flexShrink={0} wrapMode="word" fg={progress().attention ? props.colors.warning : props.colors.text}>{progress().detail}</text>
              <text flexShrink={0} wrapMode="word" fg={props.colors.text}>{progress().latest}</text>
            </>
          )}
        </Show>
      </scrollbox>
    </box>
  );
}
