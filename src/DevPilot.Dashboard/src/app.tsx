import { spawn } from "node:child_process";
import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid";
import { decideLayout, type LayoutDecision } from "./layout.js";
import {
  age,
  duration,
  eventNarrative,
  eventSummary,
  line,
  roleLabel,
  shortCommit,
  shortId,
  statusColor,
} from "./format.js";
import { liveElapsedMilliseconds, OperationsReducer, totalElapsedMilliseconds } from "./reducer.js";
import type { AgentRole, BlockedWarning, Completion, InstanceState, ViewFilter } from "./domain.js";
import { PullRequestHistoryProjection, type PullRequestHistoryEntry } from "./history.js";
import type { EventTailer } from "./tailer.js";
import {
  BrokerRejectionError,
  type CapabilitySummary,
  type DispatchAccepted,
  type DispatchBroker,
  type DispatchTerminal,
} from "./dispatch.js";

export const BRAND_PLANE = ["       __|__       ", "--o--o--(_)--o--o--"] as const;
export const HELP_LEGEND = [
  "Live = active work; Current session = Live plus newest retained per group.",
  "History = stopped/completed retained runs; Stale = heartbeat overdue.",
  "Forget never deletes agent state or event logs; unavailable actions report status.",
] as const;

const COLORS = {
  bg: "#08090a",
  panel: "#0f1011",
  panelAlt: "#18191d",
  border: "#34343b",
  brand: "#5e6ad2",
  interactive: "#7170ff",
  accent: "#828fff",
  text: "#f7f8f8",
  muted: "#92939b",
  warning: "#f0b45a",
  error: "#ff6b6b",
  ok: "#61d6a7",
};

type Overlay = "none" | "events" | "palette" | "help";
type RoleFilter = "all" | AgentRole;
type PaneFocus = "rail" | "detail" | "timeline" | "inspector";

export interface AppProps {
  reducer: OperationsReducer;
  history?: PullRequestHistoryProjection;
  tailer: EventTailer;
  openUrl?: (url: string) => void | Promise<void>;
  broker?: DispatchBroker | undefined;
  brokerFailure?: () => string;
  shutdownBroker?: () => Promise<void>;
}

type ManualMode = "closed" | "prompt" | "describing" | "confirm" | "confirm-final" | "dispatching" | "active" | "terminal";

export function normalizeOperatorPrompt(value: string): string {
  return value.replace(/\r\n?/g, "\n");
}

export function promptScalarCount(value: string): number {
  return Array.from(normalizeOperatorPrompt(value)).length;
}

export function appendPromptScalar(current: string, scalar: string): string {
  const scalarValues = Array.from(scalar);
  if (scalarValues.length !== 1 || scalarValues[0]!.codePointAt(0)! >= 0xd800 &&
      scalarValues[0]!.codePointAt(0)! <= 0xdfff) return current;
  const next = `${normalizeOperatorPrompt(current)}${scalar}`;
  if (promptScalarCount(next) > 512) return current;
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u.test(scalar)) return current;
  return next;
}

export function printableKeySequence(key: {
  name: string;
  sequence?: string;
  ctrl?: boolean;
  meta?: boolean;
}): string | null {
  if (key.ctrl || key.meta) return null;
  const candidate = key.name === "space" ? " " : key.sequence || key.name;
  if (Array.from(candidate).length !== 1) return null;
  if (/[\u0000-\u001f\u007f-\u009f]/u.test(candidate)) return null;
  return candidate;
}

export function selectableCount(
  selectedView: ViewFilter,
  hasHistory: boolean,
  historyLength: number,
  instanceLength: number,
): number {
  return selectedView === "history" && hasHistory ? historyLength : instanceLength;
}

export function dispatchResultDetail(code: string, detail = ""): string {
  const safe = line(detail.replace(/[\u0000-\u001f\u007f-\u009f]/g, " "), 160);
  const labels: Record<string, string> = {
    "source-changed": "Source changed after confirmation; describe the PR again.",
    "policy-changed": "Manual capability policy changed; describe the PR again.",
    "pr-state-changed": "Bound PR state changed; describe the PR again.",
    "delivery-pending": "Reviewer delivery is pending; resolve or promote it before redispatch.",
    "already-running": safe.includes("state-contended")
      ? "Already running: repository role state is busy."
      : "Already running: this PR and role hold the work lease.",
    "launch-failed": "Broker could not safely launch the child.",
    "role-not-allowed": "This manual role is not enabled by the trusted launcher.",
  };
  return `${labels[code] ?? `Dispatch rejected: ${code}`}${safe ? ` ${safe}` : ""}`;
}

function ManualDispatchPanel(props: {
  mode: ManualMode;
  entry: PullRequestHistoryEntry;
  role: AgentRole;
  prompt: string;
  summary: CapabilitySummary | null;
  accepted: DispatchAccepted | null;
  status: string;
}) {
  const promptPreview = () => line(props.prompt.replace(/\n/g, " / ") || "(none)", 90);
  const identity = () => props.summary?.repositoryIdentity ?? props.entry.repositoryIdentity;
  const pullRequestId = () => props.summary?.prSnapshot.pullRequestId ?? props.entry.pullRequestId;
  const title = () => props.summary?.prSnapshot.title ?? props.entry.title;
  const author = () => props.summary?.prSnapshot.author ?? props.entry.author;
  return (
    <Panel title="MANUAL DISPATCH" flexGrow={1} borderColor={COLORS.warning}>
      <box flexDirection="column" flexGrow={1}>
        <text height={1} fg={COLORS.accent}>{identity().slug} / PR #{pullRequestId()}</text>
        <text height={1} fg={COLORS.text}>{line(title() || "(untitled)", 100)} | {line(author() || "unknown author", 60)}</text>
        <text height={1} fg={COLORS.text}>Role: {roleLabel(props.role)} | force fresh analysis</text>
        <Show when={props.mode === "prompt"}>
          <text height={1} fg={COLORS.warning}>Operator context is untrusted data; 512 Unicode scalars maximum.</text>
          <text height={1} fg={COLORS.text}>{promptPreview()}</text>
          <text height={1} fg={COLORS.muted}>{promptScalarCount(props.prompt)}/512 | Enter newline | Ctrl+D describe | Esc close</text>
        </Show>
        <Show when={props.mode === "describing" || props.mode === "dispatching"}>
          <text height={1} fg={COLORS.warning}>{props.mode === "describing" ? "Fetching fresh provider and wrapper policy..." : "Starting contained broker-owned child..."}</text>
        </Show>
        <Show when={props.summary}>
          {(summary: () => CapabilitySummary) => (
            <>
              <text height={1} fg={COLORS.text}>Source: {shortCommit(summary().prSnapshot.sourceCommit)} | {summary().prSnapshot.sourceRef} -&gt; {summary().prSnapshot.targetRef}</text>
              <text height={1} fg={COLORS.ok}>Policy digest: {shortCommit(summary().capabilityPolicyDigest)} confirmed</text>
              <text height={1} fg={COLORS.ok}>PR-state fingerprint: {shortCommit(summary().prStateFingerprint)} confirmed</text>
              <text height={1} fg={COLORS.text}>Enabled: {line(summary().capabilities.join(", ") || "none", 100)}</text>
              <text height={1} fg={COLORS.warning}>Disabled high-impact: {line(summary().mandatoryDenies.join(", ") || "none reported", 100)}</text>
              <For each={summary().dynamicConstraints}>
                {(constraint) => <text height={1} fg={COLORS.warning}>Constraint: {line(constraint, 100)}</text>}
              </For>
              <Show when={props.mode === "confirm"}>
                <text height={1} fg={COLORS.warning}>First confirmation: press d to review the final execution gate; Esc cancels.</text>
              </Show>
              <Show when={props.mode === "confirm-final"}>
                <text height={1} fg={COLORS.error}>FINAL CONFIRMATION: press y to dispatch this exact snapshot; Esc cancels.</text>
              </Show>
            </>
          )}
        </Show>
        <Show when={props.accepted}>
          {(accepted: () => DispatchAccepted) => (
            <>
              <text height={1} fg={COLORS.ok}>Accepted dispatch {shortId(accepted().dispatchId)} | child PID {accepted().childProcessId}</text>
              <text height={1} fg={COLORS.text}>Correlated v3 events: {line(accepted().eventLogPath, 100)}</text>
              <text height={1} fg={COLORS.warning}>Press c to cancel only this broker-owned manual child.</text>
            </>
          )}
        </Show>
        <Show when={props.status}>
          <text height={1} fg={props.mode === "terminal" ? COLORS.warning : COLORS.muted}>{line(props.status, 160)}</text>
        </Show>
      </box>
    </Panel>
  );
}

function History(props: {
  entries: PullRequestHistoryEntry[];
  selected: number;
  compact: boolean;
}) {
  const selected = () => props.entries[Math.min(props.selected, Math.max(0, props.entries.length - 1))];
  return (
    <>
      <Panel title={`PR HISTORY ${props.entries.length}`} width={props.compact ? "100%" : 38} borderColor={COLORS.interactive}>
        <Show when={props.entries.length} fallback={<Empty />}>
          <scrollbox flexGrow={1} scrollY>
            <For each={props.entries}>
              {(entry, index) => (
                <box height={4} paddingX={1} backgroundColor={index() === props.selected ? COLORS.panelAlt : COLORS.panel}>
                  <text height={1} fg={index() === props.selected ? COLORS.accent : COLORS.text}>
                    {index() === props.selected ? "> " : "  "}{entry.repositoryIdentity.repositoryName} PR #{entry.pullRequestId}
                  </text>
                  <text height={1} fg={COLORS.text}>{line(entry.title || "title not reported", 32)}</text>
                  <text height={1} fg={COLORS.muted}>{line(entry.author || "author unknown", 32)}</text>
                </box>
              )}
            </For>
          </scrollbox>
        </Show>
      </Panel>
      <Show when={!props.compact}>
        <Panel title="RETAINED OUTCOMES" flexGrow={1}>
          <Show when={selected()} fallback={<Empty />}>
            {(entry: () => PullRequestHistoryEntry) => (
              <box flexDirection="column">
                <text height={1} fg={COLORS.accent}>{entry().repositoryIdentity.slug} / PR #{entry().pullRequestId}</text>
                <text height={1} fg={COLORS.text}>{line(entry().title || "title not reported", 100)}</text>
                <text height={1} fg={COLORS.muted}>{entry().author || "author unknown"} | {entry().sourceBranch || "?"} -&gt; {entry().targetBranch || "?"}</text>
                <text height={1} fg={COLORS.text}>Reviewer: {entry().outcomes.reviewer?.result ?? "no terminal outcome"}</text>
                <text height={1} fg={COLORS.text}>Handler: {entry().outcomes["review-handler"]?.result ?? "no terminal outcome"}</text>
                <text height={1} fg={COLORS.muted}>Canonical key: {line(entry().key, 100)}</text>
              </box>
            )}
          </Show>
        </Panel>
      </Show>
    </>
  );
}

interface PaletteCommand {
  label: string;
  enabled: boolean;
  unavailable: string;
  run: () => void;
}

export function safeHttpUrl(value: string): string | null {
  if (!value || value.length > 2_048) return null;
  try {
    const parsed = new URL(value);
    if (
      (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
      !parsed.hostname ||
      parsed.username ||
      parsed.password
    ) {
      return null;
    }
    return parsed.href;
  } catch {
    return null;
  }
}

export function defaultOpenUrl(value: string): Promise<void> {
  const url = safeHttpUrl(value);
  if (!url) return Promise.reject(new Error("PR URL is missing or unsupported"));

  const platform = process.platform;
  const command =
    platform === "win32" ? "rundll32.exe" : platform === "darwin" ? "open" : platform === "linux" ? "xdg-open" : "";
  const args =
    platform === "win32" ? ["url.dll,FileProtocolHandler", url] : command ? [url] : [];
  if (!command) return Promise.reject(new Error(`URL opening is unavailable on ${platform}`));

  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
      shell: false,
    });
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });
}

export function completionResultColor(result: string): string {
  const normalized = result.toLowerCase();
  if (normalized.includes("fail")) return COLORS.error;
  if (normalized.includes("partial")) return COLORS.warning;
  return COLORS.ok;
}

function Panel(props: {
  title: string;
  width?: number | `${number}%`;
  children: unknown;
  borderColor?: string;
  flexGrow?: number;
}) {
  const dimensions = {
    ...(props.width === undefined ? {} : { width: props.width }),
    ...(props.flexGrow === undefined ? {} : { flexGrow: props.flexGrow }),
  };
  return (
    <box
      title={` ${props.title} `}
      border
      borderStyle="single"
      borderColor={props.borderColor ?? COLORS.border}
      backgroundColor={COLORS.panel}
      {...dimensions}
      paddingX={1}
      overflow="hidden"
    >
      {props.children}
    </box>
  );
}

function Empty() {
  return (
    <box flexGrow={1} alignItems="center" justifyContent="center" flexDirection="column" height={5}>
      <text height={1} fg={COLORS.brand}>{BRAND_PLANE[0]}</text>
      <text height={1} fg={COLORS.interactive}>{BRAND_PLANE[1]}</text>
      <text height={1} fg={COLORS.muted}>Waiting for DevPilot event streams...</text>
    </box>
  );
}

function streamLabel(instance: InstanceState): string {
  if (instance.lifecycle === "stopped" || instance.status === "completed") return "History";
  if (instance.status === "stale") return "Stale";
  return "Live";
}

function isHistoricalInstance(instance: InstanceState | undefined): boolean {
  return Boolean(instance && (instance.lifecycle === "stopped" || instance.status === "completed"));
}

function viewLabel(view: ViewFilter): string {
  if (view === "current") return "Current session";
  return view[0]?.toUpperCase() + view.slice(1);
}

function Rail(props: {
  instances: InstanceState[];
  selected: number;
  now: number;
  compact: boolean;
  focused: boolean;
}) {
  return (
    <Panel
      title={`${props.focused ? "● " : ""}INSTANCES ${props.instances.length}`}
      width={props.compact ? "100%" : 32}
      borderColor={props.focused ? COLORS.interactive : COLORS.border}
    >
      <Show when={props.instances.length} fallback={<Empty />}>
        <scrollbox flexGrow={1} scrollY>
          <For each={props.instances}>
            {(instance, index) => {
              const selected = () => index() === props.selected;
              const startsGroup = () => {
                const previous = props.instances[index() - 1];
                return !previous ||
                  previous.agent !== instance.agent ||
                  previous.sessionNamespace !== instance.sessionNamespace;
              };
              const historical = () => isHistoricalInstance(instance);
              return (
                <>
                  <Show when={startsGroup()}>
                    <text height={1} fg={COLORS.accent}>
                      {roleLabel(instance.agent)} / {line(instance.sessionNamespace, 18)}
                    </text>
                  </Show>
                  <box
                    height={6}
                    backgroundColor={selected() ? COLORS.panelAlt : COLORS.panel}
                    paddingX={1}
                    border={selected() ? ["left"] : false}
                    borderColor={statusColor(instance.status)}
                    flexDirection="column"
                  >
                    <text height={1} fg={statusColor(instance.status)}>
                      {selected() ? "> " : "  "}{streamLabel(instance)} / {historical() ? instance.completion?.result || instance.status : instance.status}
                    </text>
                    <text height={1} fg={COLORS.text}>
                      {shortId(instance.instanceId)} {historical() ? `| ${instance.completion?.result || instance.status}` : `| PID ${instance.processId}`}
                    </text>
                    <text height={1} fg={COLORS.muted}>{line(instance.repository || "repository unknown", 26)}</text>
                    <text height={1} fg={COLORS.text}>
                      {instance.pullRequestId ? `PR #${instance.pullRequestId} ${line(instance.pullRequestTitle, 15)}` : `cycle ${instance.cycleNumber || "-"}`}
                    </text>
                    <text height={1} fg={COLORS.muted}>
                      {historical() ? "Ended " : "Event "}{new Date(instance.completion?.timestampMs ?? instance.lastEventMs).toISOString().slice(11, 19)}Z | {age(instance.completion?.timestampMs ?? instance.lastEventMs, props.now)}
                    </text>
                  </box>
                </>
              );
            }}
          </For>
        </scrollbox>
      </Show>
    </Panel>
  );
}

function WarningBlock(props: { instance: InstanceState }) {
  return (
    <>
      <Show when={props.instance.blocked}>
        {(blocked: () => BlockedWarning) => (
          <box
            border
            borderStyle="single"
            borderColor={COLORS.warning}
            backgroundColor="#282117"
            height={blocked().nextRetry ? 5 : 4}
            paddingX={1}
            flexDirection="column"
          >
            <text height={1} fg={COLORS.warning}>BLOCKED: {line(blocked().reason, 100)}</text>
            <text height={1} fg={COLORS.text}>
              Outstanding: {blocked().outstanding.join(", ") || "not reported"} | Retryable: {blocked().retryable ? "yes" : "no"}
            </text>
            <Show when={blocked().nextRetry}>
              <text height={1} fg={COLORS.muted}>Next retry: {blocked().nextRetry}</text>
            </Show>
          </box>
        )}
      </Show>
      <Show when={!props.instance.blocked && props.instance.retryable}>
        <box border borderStyle="single" borderColor={COLORS.warning} backgroundColor="#282117" height={3} paddingX={1}>
          <text height={1} fg={COLORS.warning}>
            RETRY PENDING: {props.instance.outstanding.join(", ") || "capabilities not reported"}
          </text>
        </box>
      </Show>
    </>
  );
}

function FieldColumn(props: {
  label: string;
  value: string;
  detail?: string;
  valueColor?: string;
}) {
  return (
    <box flexDirection="column" flexGrow={1} minWidth={0} height={3}>
      <text height={1} fg={COLORS.muted}>{props.label}</text>
      <text height={1} fg={props.valueColor ?? COLORS.text}>{props.value}</text>
      <Show when={props.detail !== undefined}>
        <text height={1} fg={COLORS.muted}>{props.detail}</text>
      </Show>
    </box>
  );
}

function CompletionBlock(props: { completion: Completion }) {
  const delivery = () => props.completion.delivered.join(", ") || "none";
  const requested = () => props.completion.requested.join(", ") || "not reported";
  const detail = () =>
    props.completion.reason ||
    props.completion.summary ||
    (props.completion.previewArtifact ? `Preview: ${props.completion.previewArtifact}` : "");
  return (
    <box flexDirection="column" height={5}>
      <text height={1} fg={COLORS.muted}>END-OF-RUN SUMMARY</text>
      <text height={1} fg={completionResultColor(props.completion.result)}>
        {props.completion.result} | critical {props.completion.findings.critical} | important {props.completion.findings.important} | suggestion {props.completion.findings.suggestion}
      </text>
      <text height={1} fg={COLORS.text}>Requested: {line(requested(), 45)} | Delivered: {line(delivery(), 45)}</text>
      <text height={1} fg={props.completion.reason ? COLORS.warning : COLORS.muted}>{line(detail() || "No summary reported", 110)}</text>
      <text height={1} fg={COLORS.muted}>
        {props.completion.previewArtifact ? `Preview ${line(props.completion.previewArtifact, 48)}` : "No preview artifact"}
        {" | "}{props.completion.nextScan ? `Next ${line(props.completion.nextScan, 42)}` : "Next scan not reported"}
      </text>
    </box>
  );
}

function Detail(props: {
  instance: InstanceState | undefined;
  now: number;
  focus: PaneFocus;
}) {
  const timelineFocused = () => props.focus === "timeline";
  return (
    <Panel
      title={props.instance ? `${props.focus === "detail" || timelineFocused() ? "● " : ""}${roleLabel(props.instance.agent)} / ${shortId(props.instance.instanceId)}${timelineFocused() ? " / TIMELINE" : ""}` : "DETAIL"}
      flexGrow={1}
      borderColor={props.focus === "detail" || timelineFocused() ? COLORS.interactive : props.instance ? statusColor(props.instance.status) : COLORS.border}
    >
      <Show when={props.instance} fallback={<Empty />}>
        {(instance: () => InstanceState) => (
          <box flexDirection="column" flexGrow={1}>
            <WarningBlock instance={instance()} />
            <box flexDirection="row" gap={2} height={3}>
              <FieldColumn
                label="CURRENT PHASE"
                value={line(instance().phase, 55)}
                detail={`phase ${duration(liveElapsedMilliseconds(instance(), props.now))} | total ${duration(totalElapsedMilliseconds(instance(), props.now))}`}
                valueColor={COLORS.accent}
              />
              <FieldColumn
                label="MODEL ACTIVITY"
                value={line(instance().modelActivity, 52)}
                detail={`cycle ${instance().cycleNumber || "-"} | ${streamLabel(instance())}`}
              />
            </box>

            <box flexDirection="row" gap={2} height={3}>
              <FieldColumn
                label="PULL REQUEST"
                value={instance().pullRequestId ? `#${instance().pullRequestId} ${line(instance().pullRequestTitle || "title not reported", 40)}` : "none selected"}
                detail={`${instance().pullRequestAuthor || "author unknown"} | ${instance().sourceBranch || "?"} -> ${instance().targetBranch || "?"}`}
              />
              <FieldColumn
                label="CANDIDATE STORY"
                value={line(instance().candidateStory, 54)}
                detail={`threads ${instance().actionableThreadCount}/${instance().threadCount} actionable | files ${instance().changedFileCount} | scan ${instance().candidates.scanned}/${instance().candidates.selected}/${instance().candidates.skipped}`}
              />
            </box>

            <box flexDirection="column" height={2}>
              <text height={1} fg={COLORS.muted}>PR LINK / COMMIT</text>
              <text height={1} fg={instance().pullRequestUrl ? COLORS.interactive : COLORS.muted}>
                {instance().pullRequestUrl ? `o open ${line(instance().pullRequestUrl, 90)}` : "PR URL not reported"} | commit {shortCommit(instance().sourceCommit)}
              </text>
            </box>

            <Show when={instance().completion}>
              {(completion: () => Completion) => <CompletionBlock completion={completion()} />}
            </Show>

            <text height={1} fg={timelineFocused() ? COLORS.accent : COLORS.muted}>CURRENT-RUN TIMELINE</text>
            <scrollbox flexGrow={1} scrollY stickyScroll stickyStart="bottom">
              <For each={instance().timeline.filter((event) => event.timestampMs >= instance().currentRunStartedMs).slice(-30)}>
                {(event) => (
                  <text height={1} fg={event.level === "error" ? COLORS.error : event.level === "warning" ? COLORS.warning : COLORS.text}>
                    {new Date(event.timestampMs).toISOString().slice(11, 19)} {line(eventNarrative(event), 108)}
                  </text>
                )}
              </For>
            </scrollbox>
          </box>
        )}
      </Show>
    </Panel>
  );
}

function Inspector(props: { instance: InstanceState | undefined; focused?: boolean }) {
  return (
    <Panel title={`${props.focused ? "● " : ""}INSPECTOR`} width={36} borderColor={props.focused ? COLORS.interactive : COLORS.border}>
      <Show when={props.instance} fallback={<Empty />}>
        {(instance: () => InstanceState) => (
          <box flexDirection="column">
            <text height={1} fg={COLORS.muted}>SCOPE</text>
            <text height={1} fg={COLORS.text}>Organization: {line(instance().organization || "-", 20)}</text>
            <text height={1} fg={COLORS.text}>Project: {line(instance().project || "-", 25)}</text>
            <text height={1} fg={COLORS.text}>Repository: {line(instance().repository || "-", 22)}</text>
            <text height={1} fg={COLORS.text}>Target: {line(instance().target || "-", 26)}</text>
            <text height={1} fg={COLORS.muted}>CAPABILITIES</text>
            <text height={1} fg={COLORS.text}>Writes: {line(instance().writes || "not reported", 24)}</text>
            <text height={1} fg={COLORS.text}>Vote: {line(instance().vote || "not reported", 26)}</text>
            <text height={1} fg={COLORS.text}>{line(instance().capabilities.join(", ") || "not reported", 31)}</text>
            <text height={1} fg={COLORS.muted}>RAW STREAM</text>
            <text height={1} fg={statusColor(instance().status)}>
              {instance().lifecycle.toUpperCase()} / {instance().status.toUpperCase()}
            </text>
            <text height={1} fg={COLORS.text}>PID {instance().processId} | schema v{instance().schemaVersion}</text>
            <text height={1} fg={COLORS.text}>Sequence {instance().lastSequence} | gaps {instance().gapCount}</text>
            <text height={1} fg={COLORS.text}>Duplicates ignored {instance().duplicateCount}</text>
            <text height={1} fg={COLORS.muted}>Last raw event</text>
            <text height={1} fg={COLORS.text}>
              {instance().timeline.at(-1) ? line(`#${instance().timeline.at(-1)?.sequence} ${instance().timeline.at(-1)?.eventType}`, 31) : "none"}
            </text>
            <text height={1} fg={COLORS.muted}>SOURCE HEALTH</text>
            <text height={1} fg={instance().sourceDiagnostics.length ? COLORS.warning : COLORS.ok}>
              {instance().sourceDiagnostics.length ? `${instance().sourceDiagnostics.length} diagnostic(s)` : "stream healthy"}
            </text>
            <For each={instance().sourceDiagnostics.slice(-4)}>
              {(item) => <text height={1} fg={COLORS.warning}>{line(`${item.kind}: ${item.message}`, 31)}</text>}
            </For>
          </box>
        )}
      </Show>
    </Panel>
  );
}

function OverlayPanel(props: { title: string; children: unknown; width?: number; height?: number }) {
  return (
    <box
      position="absolute"
      top="15%"
      left="15%"
      width={props.width ?? 70}
      height={props.height ?? 18}
      zIndex={100}
      border
      borderStyle="double"
      borderColor={COLORS.accent}
      backgroundColor={COLORS.panel}
      title={` ${props.title} `}
      padding={1}
      flexDirection="column"
    >
      {props.children}
    </box>
  );
}

function visibleFocus(layout: LayoutDecision, focus: PaneFocus): PaneFocus {
  if (focus === "inspector" && !layout.showInspector) return layout.showDetail ? "detail" : "rail";
  if ((focus === "detail" || focus === "timeline") && !layout.showDetail) return "rail";
  if (focus === "rail" && !layout.showRail) return "detail";
  return focus;
}

export function App(props: AppProps) {
  const renderer = useRenderer();
  const dimensions = useTerminalDimensions();
  const [now, setNow] = createSignal(Date.now());
  const [revision, setRevision] = createSignal(0);
  const [selected, setSelected] = createSignal(0);
  const [detailOpen, setDetailOpen] = createSignal(false);
  const [inspectorOpen, setInspectorOpen] = createSignal(dimensions().width >= 120);
  const [focus, setFocus] = createSignal<PaneFocus>("rail");
  const [overlay, setOverlay] = createSignal<Overlay>("none");
  const [role, setRole] = createSignal<RoleFilter>("all");
  const [view, setView] = createSignal<ViewFilter>("current");
  const [eventWarningsOnly, setEventWarningsOnly] = createSignal(false);
  const [paletteIndex, setPaletteIndex] = createSignal(0);
  const [historyFilter, setHistoryFilter] = createSignal("");
  const [historyInputMode, setHistoryInputMode] = createSignal<"none" | "filter" | "jump">("none");
  const [historyInput, setHistoryInput] = createSignal("");
  const [feedback, setFeedback] = createSignal("Observer is read-only");
  const [manualMode, setManualMode] = createSignal<ManualMode>("closed");
  const [manualEntry, setManualEntry] = createSignal<PullRequestHistoryEntry | null>(null);
  const [manualRole, setManualRole] = createSignal<AgentRole>("reviewer");
  const [operatorPrompt, setOperatorPrompt] = createSignal("");
  const [capabilitySummary, setCapabilitySummary] = createSignal<CapabilitySummary | null>(null);
  const [acceptedDispatch, setAcceptedDispatch] = createSignal<DispatchAccepted | null>(null);
  const [manualStatus, setManualStatus] = createSignal("");
  let feedbackTimer: ReturnType<typeof setTimeout> | undefined;
  let localBrokerShutdown: Promise<void> | undefined;

  function shutdownBroker(): Promise<void> {
    if (props.shutdownBroker) return props.shutdownBroker();
    localBrokerShutdown ??= props.broker?.shutdown() ?? Promise.resolve();
    return localBrokerShutdown;
  }

  const refreshTimer = setInterval(() => {
    setNow(Date.now());
    setRevision((value) => value + 1);
  }, 1000);
  onCleanup(() => {
    clearInterval(refreshTimer);
    if (feedbackTimer) clearTimeout(feedbackTimer);
    void shutdownBroker();
  });

  function notify(message: string): void {
    setFeedback(line(message, 180));
    if (feedbackTimer) clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(() => setFeedback("Observer is read-only"), 2_500);
  }

  const instances = createMemo(() => {
    revision();
    const selectedRole = role();
    return props.reducer.list(now(), selectedRole === "all" ? undefined : selectedRole, view());
  });
  const historyEntries = createMemo(() => {
    revision();
    const entries = props.history?.list(historyFilter()) ?? [];
    const selectedRole = role();
    return selectedRole === "all" ? entries : entries.filter((entry) => Boolean(entry.outcomes[selectedRole]));
  });
  const historyCurrent = createMemo(() =>
    historyEntries()[Math.min(selected(), Math.max(0, historyEntries().length - 1))]);
  const current = createMemo(() => instances()[Math.min(selected(), Math.max(0, instances().length - 1))]);
  const layout = createMemo(() => decideLayout(dimensions().width, detailOpen(), inspectorOpen()));
  const activeFocus = createMemo(() => visibleFocus(layout(), focus()));
  createEffect(() => {
    const count = selectableCount(view(), Boolean(props.history), historyEntries().length, instances().length);
    if (selected() >= count) setSelected(Math.max(0, count - 1));
    const corrected = activeFocus();
    if (corrected !== focus()) setFocus(corrected);
  });
  const unsubscribeTerminal = props.broker?.subscribeTerminal((terminal: DispatchTerminal) => {
    if (terminal.dispatchId !== acceptedDispatch()?.dispatchId) return;
    const detail = terminal.operation === "cancelled"
      ? terminal.result === "cancelled-forced"
        ? "Cancellation forced after cooperative shutdown did not complete; process-tree exit observed."
        : `Cancelled ${terminal.result ?? "cooperatively"}.`
      : terminal.exitCode === 0
        ? "Manual child completed successfully."
        : `Manual child failed with exit code ${terminal.exitCode ?? "unknown"}.`;
    setManualStatus(detail);
    setManualMode("terminal");
    setRevision((value) => value + 1);
  });
  onCleanup(() => unsubscribeTerminal?.());

  function closeManual(): void {
    if (manualMode() === "active" || manualMode() === "dispatching") {
      notify("Cancel the active manual dispatch before closing");
      return;
    }
    setManualMode("closed");
    setManualEntry(null);
    setCapabilitySummary(null);
    setAcceptedDispatch(null);
    setOperatorPrompt("");
    setManualStatus("");
  }

  function openManual(): void {
    if (!props.broker) {
      notify("Observe-only launch: trusted manual broker is unavailable");
      return;
    }
    const selectedEntry = historyCurrent();
    if (view() !== "history" || !selectedEntry) {
      notify("Select a retained PR history row before manual dispatch");
      return;
    }
    setManualEntry({
      ...selectedEntry,
      repositoryIdentity: { ...selectedEntry.repositoryIdentity },
      outcomes: { ...selectedEntry.outcomes },
    });
    setManualMode("prompt");
    setCapabilitySummary(null);
    setAcceptedDispatch(null);
    setOperatorPrompt("");
    setManualStatus("");
    notify("Manual dispatch prompt opened");
  }

  async function describeManual(): Promise<void> {
    const entry = manualEntry();
    if (!props.broker || !entry || manualMode() !== "prompt") return;
    setManualMode("describing");
    setManualStatus("");
    try {
      const summary = await props.broker.describe(entry.repositoryIdentity.key, entry.pullRequestId, manualRole());
      setCapabilitySummary(summary);
      setManualMode("confirm");
      setManualStatus("Fresh provider snapshot and wrapper-derived capabilities loaded.");
    } catch (error) {
      const message = error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`;
      setManualStatus(message);
      setManualMode("terminal");
    }
  }

  async function dispatchManual(): Promise<void> {
    const summary = capabilitySummary();
    if (!props.broker || !summary || manualMode() !== "confirm-final") return;
    setManualMode("dispatching");
    setManualStatus("");
    try {
      const accepted = await props.broker.dispatch(summary, operatorPrompt());
      setAcceptedDispatch(accepted);
      props.tailer.registerEventLogPath(accepted.eventLogPath);
      setManualMode("active");
      setManualStatus("Dispatch accepted; waiting for correlated v3 child events.");
    } catch (error) {
      const message = error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`;
      setManualStatus(message);
      setManualMode("terminal");
    }
  }

  async function cancelManual(): Promise<void> {
    const accepted = acceptedDispatch();
    if (!props.broker || !accepted || manualMode() !== "active") return;
    setManualStatus("Requesting cooperative cancellation; forced cleanup follows only after the broker timeout.");
    try {
      const terminal = await props.broker.cancel(accepted.dispatchId);
      setManualStatus(
        terminal.result === "cancelled-forced"
          ? "Cancellation was forced; the broker observed complete contained-process-tree exit."
          : `Cancellation completed: ${terminal.result ?? "cooperative"}.`,
      );
      setManualMode("terminal");
    } catch (error) {
      setManualStatus(error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
      setManualMode("terminal");
    }
  }

  async function quit(): Promise<void> {
    setFeedback("Shutting down broker-owned manual work...");
    try {
      await shutdownBroker();
    } catch (error) {
      setFeedback(`Broker shutdown failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    await props.tailer.stop();
    renderer.destroy();
  }

  function focusRail(): void {
    if (layout().mode === "compact") setDetailOpen(false);
    setFocus("rail");
    notify("Instance rail focused");
  }

  function focusDetail(): void {
    if (!current()) {
      notify("No instance is available for detail");
      return;
    }
    if (layout().mode === "compact") setDetailOpen(true);
    setFocus("detail");
    notify("Live narrative focused");
  }

  function move(delta: number): void {
    if (activeFocus() !== "rail") {
      notify("Select the instance rail first (Esc or Left)");
      return;
    }
    const count = selectableCount(view(), Boolean(props.history), historyEntries().length, instances().length);
    if (!count) {
      notify("No instances are available");
      return;
    }
    setSelected((value) => (value + delta + count) % count);
    notify(delta < 0 ? "Previous instance selected" : "Next instance selected");
  }

  function nextWarning(): boolean {
    if (!instances().length) {
      notify("No instances are available");
      return false;
    }
    const start = selected();
    for (let offset = 1; offset <= instances().length; offset++) {
      const index = (start + offset) % instances().length;
      const candidate = instances()[index];
      if (candidate && (candidate.status === "failed" || candidate.status === "blocked" || candidate.sourceDiagnostics.length > 0)) {
        setSelected(index);
        if (layout().mode === "compact") setDetailOpen(true);
        setFocus("detail");
        notify(`Attention item selected: ${candidate.status}`);
        return true;
      }
    }
    notify("No failed, blocked, or diagnostic-bearing instance");
    return false;
  }

  async function openCurrentUrl(): Promise<void> {
    const url = safeHttpUrl(current()?.pullRequestUrl ?? "");
    if (!url) {
      notify("PR URL is missing or unsupported");
      return;
    }

    try {
      await (props.openUrl ?? defaultOpenUrl)(url);
      notify("Opened validated PR URL");
    } catch (error) {
      notify(`Could not open PR URL: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  function cycleView(direction = 1): void {
    const values: ViewFilter[] = ["live", "current", "history"];
    const next = values[(values.indexOf(view()) + direction + values.length) % values.length] ?? "current";
    setView(next);
    setSelected(0);
    setFocus("rail");
    if (layout().mode === "compact") setDetailOpen(false);
    notify(`View filter changed to ${viewLabel(next)}`);
  }

  function forgetCurrentHistory(): void {
    if (view() === "history" && props.history) {
      const entry = historyEntries()[selected()];
      if (!entry || !props.history.hide(entry.key)) {
        notify("No PR history row is selected");
        return;
      }
      setRevision((value) => value + 1);
      notify("PR history row hidden for this dashboard process");
      return;
    }
    const instance = current();
    if (!instance || !props.reducer.forgetHistorical(instance.key)) {
      notify(instance ? "Selected instance is not historical" : "No historical instance is selected");
      return;
    }
    setRevision((value) => value + 1);
    notify("Historical row forgotten for this dashboard process");
  }

  function forgetAllHistory(): void {
    if (view() === "history" && props.history) {
      const restored = props.history.restoreAll();
      setRevision((value) => value + 1);
      notify(restored ? `${restored} PR history row(s) restored for this dashboard process` : "No hidden PR history rows are available");
      return;
    }

    const forgotten = props.reducer.forgetAllHistorical();
    if (!forgotten) {
      notify("No visible historical rows are available to forget");
      return;
    }
    setRevision((value) => value + 1);
    notify(`${forgotten} historical row(s) forgotten for this dashboard process`);
  }

  function commitHistoryInput(): void {
    if (!props.history) return;
    if (historyInputMode() === "filter") {
      setHistoryFilter(historyInput());
      setSelected(0);
      notify(historyInput() ? `PR history filter: ${historyInput()}` : "PR history filter cleared");
    } else if (historyInputMode() === "jump") {
      const pullRequestId = Number(historyInput());
      const selectedRole = role();
      const matches = props.history.matches(pullRequestId, historyFilter())
        .filter((entry) => selectedRole === "all" || Boolean(entry.outcomes[selectedRole]));
      if (matches.length !== 1) {
        notify("PR jump is missing, excluded by the active role, or ambiguous across repositories");
      } else {
        const entry = matches[0]!;
        props.history.restore(entry.key);
        setRevision((value) => value + 1);
        const index = props.history.list(historyFilter())
          .filter((item) => selectedRole === "all" || Boolean(item.outcomes[selectedRole]))
          .findIndex((item) => item.key === entry.key);
        setSelected(index);
        notify(`Jumped to ${entry.repositoryIdentity.repositoryName} PR #${entry.pullRequestId}`);
      }
    }
    setHistoryInputMode("none");
    setHistoryInput("");
  }

  const warningAvailable = createMemo(() =>
    instances().some((item) => item.status === "failed" || item.status === "blocked" || item.sourceDiagnostics.length > 0),
  );
  const palette = createMemo<PaletteCommand[]>(() => [
    {
      label: "Focus instance rail",
      enabled: activeFocus() !== "rail",
      unavailable: "Instance rail is already focused",
      run: focusRail,
    },
    {
      label: "Focus live narrative",
      enabled: Boolean(current()) && activeFocus() !== "detail",
      unavailable: current() ? "Live narrative is already focused" : "No instance is available",
      run: focusDetail,
    },
    {
      label: inspectorOpen() ? "Close inspector" : "Open inspector",
      enabled: layout().mode !== "compact" || detailOpen(),
      unavailable: "Open detail before the compact inspector",
      run: () => {
        const opening = !inspectorOpen();
        setInspectorOpen(opening);
        setFocus(opening ? "inspector" : "detail");
        notify(opening ? "Inspector opened and focused" : "Inspector closed");
      },
    },
    {
      label: "Next attention item",
      enabled: warningAvailable(),
      unavailable: "No attention item is available",
      run: () => void nextWarning(),
    },
    {
      label: "Open validated PR URL",
      enabled: safeHttpUrl(current()?.pullRequestUrl ?? "") !== null,
      unavailable: "PR URL is missing or unsupported",
      run: () => void openCurrentUrl(),
    },
    {
      label: "Forget selected historical row (view only)",
      enabled: isHistoricalInstance(current()),
      unavailable: current() ? "Selected instance is not historical" : "No historical instance is selected",
      run: forgetCurrentHistory,
    },
    {
      label: "Forget all historical rows (view only)",
      enabled: props.reducer.list(now(), undefined, "history").length > 0,
      unavailable: "No visible historical rows are available to forget",
      run: forgetAllHistory,
    },
    {
      label: "Show keyboard help",
      enabled: true,
      unavailable: "",
      run: () => setOverlay("help"),
    },
  ]);

  function executePalette(): void {
    const command = palette()[paletteIndex()];
    if (!command) return;
    if (!command.enabled) {
      notify(command.unavailable);
      return;
    }
    setOverlay("none");
    command.run();
  }

  useKeyboard((key) => {
    if (manualMode() !== "closed") {
      if (manualMode() === "prompt") {
        if (key.name === "escape") closeManual();
        else if (key.ctrl && key.name === "d") void describeManual();
        else if (key.name === "tab") {
          setManualRole((value) => value === "reviewer" ? "review-handler" : "reviewer");
          setCapabilitySummary(null);
        } else if (key.name === "backspace") {
          setOperatorPrompt((value) => Array.from(value).slice(0, -1).join(""));
        } else if (key.name === "return") {
          setOperatorPrompt((value) => appendPromptScalar(value, "\n"));
        } else {
          const printable = printableKeySequence(key);
          if (printable !== null) {
            setOperatorPrompt((value) => appendPromptScalar(value, printable));
          }
        }
      } else if (manualMode() === "confirm") {
        if (key.name === "escape") closeManual();
        else if (key.name === "d") setManualMode("confirm-final");
      } else if (manualMode() === "confirm-final") {
        if (key.name === "escape") closeManual();
        else if (key.name === "y") void dispatchManual();
      } else if (manualMode() === "active" && key.name === "c") {
        void cancelManual();
      } else if (manualMode() === "terminal" && (key.name === "escape" || key.name === "return")) {
        closeManual();
      }
      return;
    }
    if (view() === "history" && props.history && historyInputMode() !== "none") {
      if (key.name === "escape") {
        setHistoryInputMode("none");
        setHistoryInput("");
        notify("History input cancelled");
      } else if (key.name === "backspace") {
        setHistoryInput((value) => value.slice(0, -1));
      } else if (key.name === "return") {
        commitHistoryInput();
      } else {
        const printable = printableKeySequence(key);
        if (printable !== null &&
            (historyInputMode() === "filter" || /^[0-9]$/.test(printable))) {
          setHistoryInput((value) => `${value}${printable}`.slice(0, 80));
        }
      }
      return;
    }
    if (key.ctrl && key.name === "p") {
      setOverlay("palette");
      setPaletteIndex(0);
      notify("Command palette opened");
      return;
    }
    if (overlay() === "palette") {
      if (key.name === "escape") {
        setOverlay("none");
        notify("Command palette closed");
      } else if (key.name === "up" || key.name === "k") {
        setPaletteIndex((value) => (value + palette().length - 1) % palette().length);
      } else if (key.name === "down" || key.name === "j") {
        setPaletteIndex((value) => (value + 1) % palette().length);
      } else if (key.name === "return") executePalette();
      return;
    }
    if (overlay() === "events") {
      if (key.name === "escape") {
        setOverlay("none");
        notify("Events overlay closed");
      } else if (key.name === "left" || key.name === "right" || key.name === "e") {
        setEventWarningsOnly((value) => !value);
        notify(eventWarningsOnly() ? "Showing warning and error events" : "Showing all events");
      }
      return;
    }
    if (overlay() === "help") {
      if (key.name === "escape" || key.name === "?") {
        setOverlay("none");
        notify("Help closed");
      }
      return;
    }

    if (key.name === "q") {
      void quit();
    } else if (key.name === "up" || key.name === "k") move(-1);
    else if (key.name === "down" || key.name === "j") move(1);
    else if (key.name === "return") {
      if (activeFocus() === "rail") focusDetail();
      else if (activeFocus() === "detail") {
        setFocus("timeline");
        notify("Current-run timeline focused");
      } else {
        notify(activeFocus() === "timeline" ? "Timeline is already focused" : "Inspector is already focused");
      }
    } else if (key.name === "escape" || key.name === "b") {
      if (activeFocus() === "timeline" || activeFocus() === "inspector") {
        setFocus("detail");
        if (layout().inspectorOverlay) setInspectorOpen(false);
        notify("Live narrative focused");
      } else if (activeFocus() === "detail") focusRail();
      else notify("Instance rail is already focused");
    } else if (key.name === "left") {
      if (activeFocus() === "rail") notify("Instance rail is the leftmost pane");
      else focusRail();
    } else if (key.name === "right") {
      if (activeFocus() === "rail") focusDetail();
      else if (activeFocus() === "detail" || activeFocus() === "timeline") {
        if (layout().showInspector) {
          setFocus("inspector");
          notify("Inspector focused");
        } else notify("Inspector is closed; press i to open it");
      } else notify("Inspector is the rightmost pane");
    } else if (key.name === "i") {
      if (layout().mode === "compact" && !detailOpen()) {
        notify("Open detail before the compact inspector");
      } else {
        const opening = !inspectorOpen();
        setInspectorOpen(opening);
        setFocus(opening ? "inspector" : "detail");
        notify(opening ? "Inspector opened and focused" : "Inspector closed");
      }
    } else if (key.name === "e") {
      setOverlay("events");
      notify("Raw events overlay opened");
    } else if (key.name === "w") void nextWarning();
    else if (key.name === "o") void openCurrentUrl();
    else if (view() === "history" && props.history && key.name === "/") {
      setHistoryInputMode("filter");
      setHistoryInput(historyFilter());
      notify("Enter a case-insensitive PR history filter");
    }
    else if (view() === "history" && props.history && /^[0-9]$/.test(key.name)) {
      setHistoryInputMode("jump");
      setHistoryInput(key.name);
      notify("Enter a PR number, then press Enter to jump");
    }
    else if (key.name === "m") openManual();
    else if (key.name === "f") cycleView(key.shift ? -1 : 1);
    else if (key.name === "x") {
      if (key.shift) forgetAllHistory();
      else forgetCurrentHistory();
    }
    else if (key.name === "?") {
      setOverlay("help");
      notify("Help opened");
    } else if (key.name === "tab") {
      const values: RoleFilter[] = ["all", "reviewer", "review-handler"];
      const direction = key.shift ? -1 : 1;
      setRole((value) => values[(values.indexOf(value) + direction + values.length) % values.length] ?? "all");
      setSelected(0);
      setFocus("rail");
      if (layout().mode === "compact") setDetailOpen(false);
      notify("Role filter changed");
    }
  });

  const overlayEvents = createMemo(() => {
    const events = current()?.timeline ?? [];
    return (eventWarningsOnly() ? events.filter((item) => item.level === "warning" || item.level === "error") : events).slice(-40);
  });
  const diagnostics = createMemo(() => {
    revision();
    return props.reducer.globalDiagnostics();
  });
  const footer = createMemo(() => {
    const live = instances().filter((item) => streamLabel(item) === "Live").length;
    const history = instances().filter((item) => streamLabel(item) === "History").length;
    const stale = instances().filter((item) => streamLabel(item) === "Stale").length;
    if (view() === "history" && props.history) {
      const input = historyInputMode() === "none" ? "" : ` | ${historyInputMode()}: ${historyInput()}`;
      const summary = `PR history ${historyEntries().length}${historyFilter() ? ` | filter: ${historyFilter()}` : ""}${input}`;
      return { summary, hint: "↑/↓ select | / filter | number jump | Tab role | x hide | X restore | m manual | f view | ? | q" };
    }
    const summary = dimensions().width < 80
      ? `${viewLabel(view())} ${instances().length} | L ${live} H ${history} S ${stale}`
      : `${viewLabel(view())} ${instances().length} | Live ${live} History ${history} Stale ${stale}`;
    if (dimensions().width >= 120) return { summary, hint: "←/→ pane | ↑/↓ select | f view | Tab role | x/X forget | Enter/Esc | i/e/o/w | Ctrl+P | ? | q" };
    if (dimensions().width >= 80) return { summary, hint: "f view | Tab role | x/X forget | Enter/Esc | i/e/o | ? | q" };
    return { summary, hint: layout().showDetail ? "Esc | f view | x forget | i/e/o | ? | q" : "↑/↓ | Enter | f view | Tab | x/X | ? | q" };
  });
  const headerContext = createMemo(() => {
    if (dimensions().width >= 120) {
      return `${viewLabel(view()).toUpperCase()} | ${role().toUpperCase()} | ${layout().mode.toUpperCase()} | FOCUS ${activeFocus().toUpperCase()}`;
    }
    if (dimensions().width >= 80) {
      return `${viewLabel(view()).toUpperCase()} | ${role().toUpperCase()} | FOCUS ${activeFocus().toUpperCase()}`;
    }
    return `${view().toUpperCase()} | ${role().toUpperCase()} | FOCUS ${activeFocus().toUpperCase()}`;
  });

  return (
    <box width="100%" height="100%" flexDirection="column" backgroundColor={COLORS.bg}>
      <box height={1} paddingX={1} flexDirection="row" justifyContent="space-between" backgroundColor={COLORS.panelAlt}>
        <text height={1} fg={COLORS.brand}>DEVPILOT OPERATIONS</text>
        <text height={1} fg={props.broker ? COLORS.warning : COLORS.muted}>
          {props.broker ? "TRUSTED MANUAL ENABLED" : "OBSERVE ONLY"} | {headerContext()}
        </text>
      </box>
      <box flexGrow={1} flexDirection="row" gap={1} padding={1} overflow="hidden">
        <Show when={manualMode() !== "closed" && manualEntry()} fallback={
          <Show when={view() === "history" && props.history} fallback={
          <>
            <Show when={layout().showRail}>
              <Rail instances={instances()} selected={selected()} now={now()} compact={layout().mode === "compact"} focused={activeFocus() === "rail"} />
            </Show>
            <Show when={layout().showDetail}>
              <Detail instance={current()} now={now()} focus={activeFocus()} />
            </Show>
            <Show when={layout().showInspector && !layout().inspectorOverlay}>
              <Inspector instance={current()} focused={activeFocus() === "inspector"} />
            </Show>
          </>
        }>
          <History entries={historyEntries()} selected={selected()} compact={layout().mode === "compact"} />
          </Show>
        }>
          {(entry: () => PullRequestHistoryEntry) => (
            <ManualDispatchPanel
              mode={manualMode()}
              entry={entry()}
              role={manualRole()}
              prompt={operatorPrompt()}
              summary={capabilitySummary()}
              accepted={acceptedDispatch()}
              status={manualStatus() || props.brokerFailure?.() || ""}
            />
          )}
        </Show>
      </box>
      <Show when={diagnostics().length > 0 || props.brokerFailure?.()}>
        <box height={1} paddingX={1} backgroundColor="#282117">
          <text height={1} fg={COLORS.warning}>
            {props.brokerFailure?.()
              ? `BROKER FAILURE: ${line(props.brokerFailure?.() ?? "", Math.max(20, dimensions().width - 20))}`
              : `SOURCE WARNING: ${line(diagnostics().at(-1)?.message ?? "event source error", Math.max(20, dimensions().width - 20))}`}
          </text>
        </box>
      </Show>
      <box height={1} paddingX={1} backgroundColor={COLORS.brand}>
        <text height={1} fg={COLORS.text}>STATUS: {line(feedback(), Math.max(10, dimensions().width - 10))}</text>
      </box>
      <box height={1} paddingX={1} flexDirection="row" justifyContent="space-between" backgroundColor={COLORS.panelAlt}>
        <text height={1} fg={COLORS.text}>{footer().summary}</text>
        <text height={1} fg={COLORS.muted}>{footer().hint}</text>
      </box>

      <Show when={layout().showInspector && layout().inspectorOverlay}>
        <OverlayPanel title="INSPECTOR" width={58} height={25}>
          <Inspector instance={current()} focused />
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "events"}>
        <OverlayPanel title={`RAW EVENTS - ${eventWarningsOnly() ? "WARNINGS" : "ALL"} (left/right filter)`} width={88} height={28}>
          <scrollbox flexGrow={1} scrollY stickyScroll stickyStart="bottom">
            <For each={overlayEvents()} fallback={<text height={1} fg={COLORS.muted}>No matching events.</text>}>
              {(event) => (
                <text height={1} fg={event.level === "error" ? COLORS.error : event.level === "warning" ? COLORS.warning : COLORS.text}>
                  #{event.sequence} {new Date(event.timestampMs).toISOString()} {line(eventSummary(event), 62)}
                </text>
              )}
            </For>
          </scrollbox>
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "palette"}>
        <OverlayPanel title="CONTEXT COMMANDS - VIEW ONLY" width={64} height={19}>
          <For each={palette()}>
            {(command, index) => (
              <text height={1} fg={!command.enabled ? COLORS.muted : index() === paletteIndex() ? COLORS.accent : COLORS.text}>
                {index() === paletteIndex() ? "> " : "  "}{command.label}{command.enabled ? "" : " [unavailable]"}
              </text>
            )}
          </For>
          <text height={1} fg={COLORS.muted}>Up/Down select | Enter run | Esc dismiss</text>
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "help"}>
        <OverlayPanel title={props.broker ? "HELP - TRUSTED MANUAL MODE" : "HELP - OBSERVE MODE"} width={78} height={25}>
          <text height={1} fg={COLORS.text}>Left / Right      Focus visible pane</text>
          <text height={1} fg={COLORS.text}>Up/Down or j/k    Select instance when rail is focused</text>
          <text height={1} fg={COLORS.text}>Enter              Drill rail → narrative → timeline</text>
          <text height={1} fg={COLORS.text}>Esc / b            Back timeline/inspector → detail → rail</text>
          <text height={1} fg={COLORS.text}>Tab / Shift+Tab    Cycle role filter</text>
          <text height={1} fg={COLORS.text}>f / Shift+f        Cycle Live, Current session, History view</text>
          <text height={1} fg={COLORS.text}>x / Shift+x        Hide selected / restore hidden PR history rows</text>
          <text height={1} fg={COLORS.text}>i                  Open/close inspector</text>
          <text height={1} fg={COLORS.text}>e                  Raw events; arrows change filter</text>
          <text height={1} fg={COLORS.text}>w                  Next attention item</text>
          <text height={1} fg={COLORS.text}>o                  Open validated http/https PR URL</text>
          <text height={1} fg={COLORS.text}>Ctrl+P             Context command palette</text>
          <text height={1} fg={COLORS.text}>m                  Manual dispatch for selected retained PR (trusted launch only)</text>
          <text height={1} fg={COLORS.text}>?                  Help</text>
          <text height={1} fg={COLORS.text}>q                  Quit</text>
          <text height={1} fg={COLORS.muted}>{HELP_LEGEND[0]}</text>
          <text height={1} fg={COLORS.muted}>{HELP_LEGEND[1]}</text>
          <text height={1} fg={COLORS.warning}>{HELP_LEGEND[2]}</text>
        </OverlayPanel>
      </Show>
    </box>
  );
}
