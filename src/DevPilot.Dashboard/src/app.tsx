import { spawn } from "node:child_process";
import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid";
import type { ScrollBoxRenderable } from "@opentui/core";
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
  type CapabilityNarrowingPreview,
  type CapabilityProfile,
  type CapabilitySummary,
  type DispatchAccepted,
  type DispatchBroker,
  type DispatchTerminal,
  type NarrowingAction,
  type NarrowingScope,
  NARROWING_SCOPES,
  type WideningCancelled,
  type WideningMinted,
  type WideningPreview,
  type WideningSummary,
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

type Overlay = "none" | "events" | "palette" | "help" | "settings";
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
    "narrowing-invalid": "The requested narrowing scope, capability, or action is not valid.",
    "narrowing-stale": "The store changed since preview; re-preview before applying.",
    "narrowing-expired": "The preview expired; re-preview before applying.",
    "narrowing-kill-switch-active": "Editing is unavailable while the kill switch is active.",
    "widening-invalid": "The requested capability widening is not valid for this draft or role.",
    "widening-expired": "The widening confirmation expired; request widening again.",
    "widening-replay": "That widening confirmation was already used; request widening again.",
    "widening-stale": "Widening state has moved on; re-open the widening panel and try again.",
    "delegation-not-allowed": "The checked-in delegation policy does not permit this capability for this repository.",
    "delegation-policy-unavailable": "The checked-in delegation policy could not be loaded; widening is unavailable right now.",
    "grant-invalidated": "The capability widening grant is no longer valid; dispatch without it or request widening again.",
    "grant-noop": "This redispatch already has prior delivery state; the auto-complete grant would be a no-op.",
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
  wideningStage: "closed" | "describing" | "preview" | "confirming" | "summary" | "minting" | "cancelling";
  wideningPreview: WideningPreview | WideningSummary | null;
  wideningStatus: string;
  mintedWideningGeneration: number | null;
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
        <text height={1} fg={COLORS.text}>
          Role: {roleLabel(props.role)} |{" "}
          {
            // Mirrors Invoke-Dispatch's own $includeForceAnalysis exactly (issue #105 PR4
            // requirement 6): -ForceAnalysis is omitted ONLY for a reviewer's minted
            // EnableApprovalVote grant (the sole capability a reviewer can ever widen) --
            // every other combination, including a review-handler's EnableAutoComplete grant,
            // keeps forcing fresh analysis exactly as an unwidened dispatch would.
            props.role === "reviewer" && props.mintedWideningGeneration !== null
              ? "vote-grant dispatch: skips forced fresh analysis (already-reviewed PR)"
              : "force fresh analysis"
          }
        </text>
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
                <Show when={props.wideningStage === "closed"}>
                  <Show when={props.mintedWideningGeneration !== null}>
                    <text height={1} fg={COLORS.ok}>Widening grant minted and active for this draft; continue with d then y to dispatch, or Esc to close and relinquish it.</text>
                  </Show>
                  <Show when={props.mintedWideningGeneration === null && summary().delegableAvailable.length === 0}>
                    <text height={1} fg={COLORS.muted}>No delegated capabilities available for this role.</text>
                  </Show>
                  <Show when={props.mintedWideningGeneration === null && summary().delegableAvailable.length === 1 && summary().killSwitchActive}>
                    <text height={1} fg={COLORS.error}>Widening unavailable while the kill switch is active.</text>
                  </Show>
                  <Show when={props.mintedWideningGeneration === null && summary().delegableAvailable.length === 1 && !summary().killSwitchActive}>
                    <text height={1} fg={COLORS.muted}>Press w to request {summary().delegableAvailable[0]} widening (draft-bound, single-use).</text>
                  </Show>
                  <text height={1} fg={COLORS.warning}>First confirmation: press d to review the final execution gate; Esc cancels.</text>
                </Show>
                <Show when={props.wideningStage === "describing"}>
                  <text height={1} fg={COLORS.warning}>Requesting capability widening description...</text>
                </Show>
                <Show when={props.wideningStage === "cancelling"}>
                  <text height={1} fg={COLORS.warning}>Cancelling capability widening...</text>
                </Show>
                <Show when={props.wideningPreview}>
                  {(stageAccessor: () => WideningPreview | WideningSummary) => {
                    const diff = () => stageAccessor().effectiveDiff;
                    return (
                      <>
                        <text height={1} fg={COLORS.accent}>
                          {props.wideningStage === "summary" || props.wideningStage === "minting" ? "Final widening blast radius" : "Widening preview"}: {stageAccessor().capability}
                        </text>
                        <text height={1} fg={COLORS.ok}>Would add: {line(diff().addedCapabilities.join(", ") || "none", 100)}</text>
                        <text height={1} fg={COLORS.warning}>Would remove from denies: {line(diff().removedDenies.join(", ") || "none", 100)}</text>
                        <Show when={diff().pairedCapability}>
                          {(paired: () => string) => (
                            <>
                              <text height={1} fg={diff().pairedCapabilityActive ? COLORS.ok : COLORS.error}>
                                Paired requirement: {paired()} must already be active{diff().pairedCapabilityActive ? " (confirmed active)" : " -- NOT active; minting refused"}.
                              </text>
                              <text height={1} fg={COLORS.muted}>Casting a vote without visible findings leaves the author an unexplained verdict.</text>
                            </>
                          )}
                        </Show>
                        <Show when={props.wideningStage === "preview"}>
                          <text height={1} fg={COLORS.muted}>Expires {line(stageAccessor().expiresAtUtc, 40)}</text>
                          <text height={1} fg={COLORS.warning}>First widening confirmation: press c to review the final blast radius; Esc cancels the widening request.</text>
                        </Show>
                        <Show when={props.wideningStage === "confirming"}>
                          <text height={1} fg={COLORS.warning}>Confirming widening preview...</text>
                        </Show>
                        <Show when={props.wideningStage === "summary"}>
                          <text height={1} fg={COLORS.warning}>Single-use grant; expires {line(stageAccessor().expiresAtUtc, 40)}.</text>
                          <text height={1} fg={COLORS.warning}>Unavailable to headless/direct/watcher dispatch -- interactive draft-bound use only.</text>
                          <text height={1} fg={COLORS.error}>FINAL WIDENING CONFIRMATION: press y to mint this grant; Esc cancels.</text>
                        </Show>
                        <Show when={props.wideningStage === "minting"}>
                          <text height={1} fg={COLORS.warning}>Minting capability widening grant...</text>
                        </Show>
                      </>
                    );
                  }}
                </Show>
                <Show when={props.wideningStatus}>
                  <text height={1} fg={COLORS.muted}>{line(props.wideningStatus, 160)}</text>
                </Show>
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

function OverlayPanel(props: {
  title: string;
  children: unknown;
  width?: number;
  height?: number;
  left?: number | "auto" | `${number}%`;
  padding?: number;
}) {
  return (
    <box
      position="absolute"
      top="15%"
      left={props.left ?? "15%"}
      width={props.width ?? 70}
      height={props.height ?? 18}
      zIndex={100}
      border
      borderStyle="double"
      borderColor={COLORS.accent}
      backgroundColor={COLORS.panel}
      title={` ${props.title} `}
      padding={props.padding ?? 1}
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
  // PR4 interactive widening sub-flow (issue #105), nested entirely inside manualMode()==="confirm"
  // -- Settings' own read-only CapabilityProfile has no dispatchDraftId to bind against, so
  // widening is only ever reachable from the trusted manual describe() flow. "preview"/"summary"
  // hold the broker's two challenge-bearing responses; the "-ing" stages are in-flight RPCs during
  // which widening keys are ignored (see the keyboard handler). wideningPreview holds whichever of
  // WideningPreview/WideningSummary is currently active, since both share the same challenge/
  // effectiveDiff/expiresAtUtc/generation shape.
  const [wideningStage, setWideningStage] =
    createSignal<"closed" | "describing" | "preview" | "confirming" | "summary" | "minting" | "cancelling">("closed");
  const [wideningPreview, setWideningPreview] = createSignal<WideningPreview | WideningSummary | null>(null);
  const [wideningStatus, setWideningStatus] = createSignal("");
  // Set the instant confirm-widening-mint succeeds; cleared on dispatch, on an explicit cancel, or
  // on closing/reopening manual dispatch. Tracks a minted-but-not-yet-dispatched grant so
  // close/quit/shutdown can still best-effort relinquish it even though wideningStage() itself has
  // already returned to "closed" (mint returns control to the ordinary confirm/confirm-final gate,
  // per issue #105 PR4 -- widening never dispatches on its own).
  const [mintedWideningGeneration, setMintedWideningGeneration] = createSignal<number | null>(null);
  const [settingsRole, setSettingsRole] = createSignal<AgentRole>("reviewer");
  const [settingsProfile, setSettingsProfile] = createSignal<CapabilityProfile | null>(null);
  const [settingsStatus, setSettingsStatus] = createSignal("");
  // PR3 narrow-only edit UX. narrowingMode is null while the read-only Settings view (PR1/PR2) is
  // showing; entering the editor stages a scope+capability selection, o/i request a preview for
  // 'off'/'inherit', and the two-stage confirm mirrors ManualDispatchPanel's confirm/confirm-final.
  const [narrowingMode, setNarrowingMode] =
    createSignal<"browsing" | "previewing" | "confirm" | "confirm-final" | "applying" | "result" | null>(null);
  const [narrowingScopeIndex, setNarrowingScopeIndex] = createSignal(0);
  const [narrowingCapabilityIndex, setNarrowingCapabilityIndex] = createSignal(0);
  const [narrowingPreview, setNarrowingPreview] = createSignal<CapabilityNarrowingPreview | null>(null);
  const [narrowingStatus, setNarrowingStatus] = createSignal("");
  // PR3 completion (issue #105): two-stage confirm, mirroring narrowingMode's own
  // confirm/confirm-final and ManualDispatchPanel's confirm/confirm-final -- "none" is the
  // ordinary read-only Settings view, "confirm" is the first (full-disclosure) warning, and
  // "confirm-final" is the terse final gate that actually arms the 'y' toggle.
  const [killSwitchStage, setKillSwitchStage] = createSignal<"none" | "confirm" | "confirm-final">("none");
  let narrowingGeneration = 0;
  // Local UI correlation token for the widening sub-flow, mirroring narrowingGeneration/
  // killSwitchGeneration exactly: bumped by every widening step and by closeManual/openManual, so
  // a response for a superseded step (panel closed/reopened meanwhile) can never be applied.
  let wideningRequestToken = 0;
  // Kill-switch generation token (issue #105 PR3 completion), mirroring narrowingGeneration/
  // settingsGeneration exactly: bumped by closeSettings and by a role switch (Tab), so a
  // setKillSwitch() response that resolves after Settings was closed or re-roled can never
  // mutate settingsStatus or trigger a refresh for a view the operator is no longer looking at.
  let killSwitchGeneration = 0;
  let feedbackTimer: ReturnType<typeof setTimeout> | undefined;
  let localBrokerShutdown: Promise<void> | undefined;
  // Settings refresh/toggle race guard: every refreshSettingsProfile() call is stamped with a
  // generation token. A response is only applied if its token still matches the latest one, so a
  // slow response from a superseded request (e.g. an earlier role, or a request outstanding when
  // Settings was closed and reopened) can never land after a newer one. settingsRefreshPending is a
  // one-in-flight gate so Tab/r are ignored while a profile request is outstanding. Both guards are
  // defense-in-depth for UI correctness now, not resource bounding: the broker's `profile` RPC
  // (unlike describe(), used only by manual dispatch) is side-effect-free -- it never allocates a
  // dispatchDraftId, config snapshot, or $drafts entry -- so overlapping profile reads from repeated
  // refreshes or close/reopen are safe and accumulate no broker-side residue; a stale/superseded
  // response must still never be applied, which is what these guards continue to protect against.
  let settingsGeneration = 0;
  let settingsRefreshPending = false;
  // PR3 palette first-use queueing (see openNarrowingEditor/tryOpenNarrowingEditor): set to the
  // settingsGeneration token of the in-flight profile load the editor-open intent is waiting on,
  // or undefined when no open is queued. Consumed (and cleared) by refreshSettingsProfile's
  // success/error paths, and force-cleared by closeSettings so a queued intent can never fire late
  // into a closed/different view.
  let pendingNarrowingEditorGeneration: number | undefined;
  // Kill-switch open queueing (issue #105 PR3 completion), mirroring
  // pendingNarrowingEditorGeneration/tryOpenNarrowingEditor exactly: set to the settingsGeneration
  // token of the in-flight profile load 'k' is waiting on, or undefined when no open is queued.
  // Consumed (and cleared) by refreshSettingsProfile's success/error paths, and force-cleared by
  // closeSettings so a queued intent can never fire late into a closed/different view.
  let pendingKillSwitchGeneration: number | undefined;
  // Renders only when the resolved profile's own role still matches the currently displayed role
  // label, independent of the request-token guard above -- a second, cheap line of defense so a
  // mislabeled profile can never reach the screen even if the guard above is ever weakened (e.g. a
  // response from a request outstanding when Settings was closed and reopened under a new role).
  const settingsDisplayProfile = createMemo(() => {
    const profile = settingsProfile();
    return profile && profile.role === settingsRole() ? profile : null;
  });
  let eventScrollbox: ScrollBoxRenderable | undefined;

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
    bestEffortCancelWidening();
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
    bestEffortCancelWidening();
    setManualMode("closed");
    setManualEntry(null);
    setCapabilitySummary(null);
    setAcceptedDispatch(null);
    setOperatorPrompt("");
    setManualStatus("");
    wideningRequestToken += 1;
    setWideningStage("closed");
    setWideningPreview(null);
    setWideningStatus("");
    setMintedWideningGeneration(null);
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
    wideningRequestToken += 1;
    setWideningStage("closed");
    setWideningPreview(null);
    setWideningStatus("");
    setMintedWideningGeneration(null);
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
      // Any minted widening grant is now consumed by the broker's own dispatch-time preflight
      // (Invoke-Dispatch sets Consumed=true unconditionally) -- a later best-effort cancel-widening
      // for this generation would only fail harmlessly, so stop tracking it.
      setMintedWideningGeneration(null);
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

  // PR4 interactive widening (issue #105). Reachable only while manualMode() === "confirm" -- see
  // the keyboard handler -- since a live CapabilitySummary/dispatchDraftId is required and Settings'
  // CapabilityProfile has none. Only ever ONE capability can be delegable per role
  // (DELEGABLE_CAPABILITY_BY_ROLE), so there is no picker: the sole entry in delegableAvailable is
  // the one this whole sub-flow requests.
  function canRequestWidening(): boolean {
    const summary = capabilitySummary();
    return manualMode() === "confirm" && wideningStage() === "closed" &&
      Boolean(summary) && !summary!.killSwitchActive && summary!.delegableAvailable.length === 1;
  }

  async function beginWidening(): Promise<void> {
    const summary = capabilitySummary();
    if (!props.broker || !summary || !canRequestWidening()) return;
    const capability = summary.delegableAvailable[0]!;
    setWideningStage("describing");
    setWideningStatus("");
    const requestId = (wideningRequestToken += 1);
    try {
      const preview = await props.broker.describeWidening(summary, capability);
      if (requestId !== wideningRequestToken) return; // superseded: manual panel closed/reset meanwhile
      setWideningPreview(preview);
      setWideningStage("preview");
    } catch (error) {
      if (requestId !== wideningRequestToken) return;
      setWideningStatus(isKillSwitchActiveRejection(error)
        ? "Widening is unavailable while the kill switch is active."
        : error instanceof BrokerRejectionError
          ? dispatchResultDetail(error.code, error.detail)
          : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
      setWideningStage("closed");
      setWideningPreview(null);
    }
  }

  async function confirmWideningPreviewStep(): Promise<void> {
    const summary = capabilitySummary();
    const stage = wideningPreview();
    if (!props.broker || !summary || !stage || wideningStage() !== "preview") return;
    setWideningStage("confirming");
    setWideningStatus("");
    const requestId = (wideningRequestToken += 1);
    try {
      const nextStage = await props.broker.confirmWideningPreview(summary, stage as WideningPreview);
      if (requestId !== wideningRequestToken) return;
      setWideningPreview(nextStage);
      setWideningStage("summary");
    } catch (error) {
      if (requestId !== wideningRequestToken) return;
      setWideningStatus(isKillSwitchActiveRejection(error)
        ? "Widening is unavailable while the kill switch is active."
        : error instanceof BrokerRejectionError
          ? dispatchResultDetail(error.code, error.detail)
          : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
      setWideningStage("closed");
      setWideningPreview(null);
    }
  }

  async function confirmWideningMintStep(): Promise<void> {
    const summary = capabilitySummary();
    const stage = wideningPreview();
    if (!props.broker || !summary || !stage || wideningStage() !== "summary") return;
    setWideningStage("minting");
    setWideningStatus("");
    const requestId = (wideningRequestToken += 1);
    try {
      const minted = await props.broker.confirmWideningMint(summary, stage as WideningSummary);
      if (requestId !== wideningRequestToken) return;
      // Merge the minted, refreshed capabilities/mandatoryDenies/digest into the manual dispatch
      // summary in place -- the existing, unmodified d/y confirm-final gate then dispatches this
      // exact widened snapshot. Widening never dispatches on its own (issue #105 PR4).
      setCapabilitySummary({
        ...summary,
        capabilities: minted.capabilities,
        mandatoryDenies: minted.mandatoryDenies,
        capabilityPolicyDigest: minted.capabilityPolicyDigest,
      });
      setMintedWideningGeneration(minted.generation);
      setWideningStage("closed");
      setWideningPreview(null);
      setWideningStatus(
        `Widening minted: ${minted.capability} granted until ${minted.grantExpiresAtUtc}. ` +
        "Continue with d then y to dispatch, or Esc to close and relinquish it.",
      );
    } catch (error) {
      if (requestId !== wideningRequestToken) return;
      setWideningStatus(isKillSwitchActiveRejection(error)
        ? "Widening is unavailable while the kill switch is active."
        : error instanceof BrokerRejectionError
          ? dispatchResultDetail(error.code, error.detail)
          : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
      setWideningStage("closed");
      setWideningPreview(null);
    }
  }

  async function cancelWideningStep(): Promise<void> {
    const summary = capabilitySummary();
    const stage = wideningPreview();
    const stageName = wideningStage();
    if (!props.broker || !summary || !stage || (stageName !== "preview" && stageName !== "summary")) return;
    setWideningStage("cancelling");
    const requestId = (wideningRequestToken += 1);
    try {
      const cancelled = await props.broker.cancelWidening(summary, stage.generation);
      if (requestId !== wideningRequestToken) return;
      setCapabilitySummary({
        ...summary,
        capabilities: cancelled.capabilities,
        mandatoryDenies: cancelled.mandatoryDenies,
        capabilityPolicyDigest: cancelled.capabilityPolicyDigest,
        delegableAvailable: cancelled.delegableAvailable,
      });
      setWideningStatus("Widening cancelled; capability profile refreshed to the unwidened baseline.");
    } catch (error) {
      if (requestId !== wideningRequestToken) return;
      setWideningStatus(error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      if (requestId === wideningRequestToken) {
        setMintedWideningGeneration(null);
        setWideningStage("closed");
        setWideningPreview(null);
      }
    }
  }

  // Best-effort only (issue #105 PR4): never awaited, never surfaced as a failure -- a widening
  // attempt or an already-minted grant is draft-scoped and expires on its own (DraftLifetimeSeconds)
  // even if this never lands, so close/quit/shutdown must never block on it.
  function bestEffortCancelWidening(): void {
    const summary = capabilitySummary();
    const stageName = wideningStage();
    const generation = mintedWideningGeneration() ??
      (stageName === "preview" || stageName === "summary" ? wideningPreview()?.generation ?? null : null);
    if (!props.broker || !summary || generation === null) return;
    void props.broker.cancelWidening(summary, generation).catch(() => {
      // Best-effort: see comment above.
    });
  }

  // Read-only effective-profile settings: uses the broker's dedicated `profile` RPC (issue #105),
  // not the manual dispatch prompt's describe(). Unlike describe(), profile() is side-effect-free
  // on the broker -- it never allocates a dispatchDraftId, config snapshot, or $drafts entry -- so
  // repeated refreshes and close/reopen concurrency can never accumulate broker-side draft residue.
  // A running agent's own profile is immutable and is never reflected here.
  //
  // targetRole is always the caller's freshly-computed role rather than a read of the
  // settingsRole() signal, and every response is stamped with (and checked against) a generation
  // token plus its own broker-authored role -- see the settingsGeneration/settingsDisplayProfile
  // comment above -- so an overlapping or superseded profile() response can never render under the
  // wrong label.
  async function refreshSettingsProfile(targetRole: AgentRole, options: { silent?: boolean } = {}): Promise<void> {
    if (settingsRefreshPending) return;
    const entry = historyCurrent();
    if (!props.broker) {
      settingsGeneration += 1;
      setSettingsProfile(null);
      // issue #105 PR3 closure: a stale confirm/confirm-final left open against a profile that
      // just disappeared would show a WARNING/FINAL CONFIRMATION for a transition this process no
      // longer has any actual profile to compute -- close it the same instant the profile clears
      // rather than leaving it visibly stuck until the next keypress (or a 'y' press) discovers
      // the loss on its own.
      setKillSwitchStage("none");
      setSettingsStatus("Unavailable: trusted manual broker is not connected (observe-only mode).");
      return;
    }
    if (!entry) {
      settingsGeneration += 1;
      setSettingsProfile(null);
      setKillSwitchStage("none");
      setSettingsStatus("Unavailable: select a retained PR history row to resolve a next-launch profile.");
      return;
    }
    const requestId = (settingsGeneration += 1);
    settingsRefreshPending = true;
    if (!options.silent) setSettingsStatus("Resolving effective profile for the next manual dispatch...");
    try {
      const profile = await props.broker.profile(entry.repositoryIdentity.key, entry.pullRequestId, targetRole);
      if (requestId !== settingsGeneration) return; // superseded: Settings closed/reopened meanwhile
      setSettingsProfile(profile);
      // Legacy-broker compatibility (issue #105 PR3 review): editingAvailable is false only when
      // this broker predates narrowing/kill-switch support entirely (see dispatch.ts's
      // parseCapabilityProfileFields) -- surface that as a persistent, always-visible status line
      // the same way the broker-not-connected/no-history-row messages above already are, rather
      // than silently no-oping the first time 'e'/'k' is pressed. Skipped for a `silent` refresh
      // (the internal re-read applyNarrowing()/toggleKillSwitch() trigger after their own mutation
      // succeeds) so it can never stomp the confirmation message those callers just set via this
      // same settingsStatus signal.
      if (!options.silent) {
        setSettingsStatus(profile.editingAvailable
          ? ""
          : "Unavailable: broker does not support capability narrowing (upgrade required).");
      }
      // PR3 palette first-use queueing: if openNarrowingEditor() was invoked before this profile
      // load resolved (e.g. the command palette's "Edit persisted capability narrowing" entry
      // picked before Settings had ever fetched a profile), fire the deferred open now that a
      // profile for the exact same generation has just landed. Reuses this function's own
      // generation guard rather than inventing a second one.
      if (pendingNarrowingEditorGeneration === requestId) {
        pendingNarrowingEditorGeneration = undefined;
        tryOpenNarrowingEditor(profile);
      }
      // Kill-switch open queueing (issue #105 PR3 completion): mirrors the narrowing-editor queue
      // immediately above -- 'k' pressed before a current, matching profile had ever loaded defers
      // here instead of racing ahead on an unknown editingAvailable/killSwitchActive state.
      if (pendingKillSwitchGeneration === requestId) {
        pendingKillSwitchGeneration = undefined;
        tryOpenKillSwitchConfirm(profile);
      }
    } catch (error) {
      if (requestId !== settingsGeneration) return;
      setSettingsProfile(null);
      // Same rationale as the broker-loss/no-entry branches above: a failed refresh means there
      // is no current profile to confirm a kill-switch transition against, so any open confirm/
      // confirm-final must close rather than linger on stale data.
      setKillSwitchStage("none");
      setSettingsStatus(error instanceof BrokerRejectionError
        ? `Unavailable: ${dispatchResultDetail(error.code, error.detail)}`
        : `Unavailable: broker failure resolving effective profile (${error instanceof Error ? error.message : String(error)}).`);
      if (pendingNarrowingEditorGeneration === requestId) pendingNarrowingEditorGeneration = undefined;
      if (pendingKillSwitchGeneration === requestId) pendingKillSwitchGeneration = undefined;
    } finally {
      if (requestId === settingsGeneration) settingsRefreshPending = false;
    }
  }

  function openSettings(): void {
    setOverlay("settings");
    setSettingsProfile(null);
    setSettingsStatus("");
    void refreshSettingsProfile(settingsRole());
    notify("Effective profile settings opened");
  }

  function closeSettings(): void {
    setOverlay("none");
    // Advance the generation and release the gate so a still-outstanding describe() from this
    // session is discarded on arrival instead of being applied, and the next open is never
    // blocked by a request the UI no longer cares about.
    settingsGeneration += 1;
    settingsRefreshPending = false;
    // A queued palette-triggered editor open must never fire late into a closed/different view.
    pendingNarrowingEditorGeneration = undefined;
    pendingKillSwitchGeneration = undefined;
    setSettingsProfile(null);
    setSettingsStatus("");
    narrowingGeneration += 1;
    setNarrowingMode(null);
    setNarrowingPreview(null);
    setNarrowingStatus("");
    // Invalidates any in-flight toggleKillSwitch() the same way narrowingGeneration invalidates an
    // in-flight narrowing mutation -- see toggleKillSwitch's own requestId guard.
    killSwitchGeneration += 1;
    setKillSwitchStage("none");
    notify("Effective profile settings closed");
  }

  // PR3 narrow-only edit UX. Every mutation is broker-owned: the dashboard never touches the
  // capability-override store directly, only requests preview/apply/kill-switch RPCs and re-reads
  // the resulting truth back through the existing side-effect-free profile() RPC.
  function narrowingCapabilities(): string[] {
    return settingsDisplayProfile()?.allowedManualCapabilities ?? [];
  }

  // Shared gate for actually entering the editor, given an already-resolved profile: used both
  // when a profile is already loaded (immediate open) and when a queued palette-triggered open
  // (see pendingNarrowingEditorGeneration below) resolves. Never invoked with a stale/superseded
  // profile -- callers only reach this once their own generation guard has already confirmed the
  // profile is current.
  function tryOpenNarrowingEditor(profile: CapabilityProfile): boolean {
    if (profile.killSwitchActive) {
      // Fail-closed UI (issue #105 PR3 review): the broker itself now rejects preview/apply while
      // the kill switch is active (BrokerRejectionError code narrowing-kill-switch-active), so the
      // editor must never even open in that state -- there is no exact preview it could ever apply.
      notify("Editing is unavailable while the kill switch is active.");
      return false;
    }
    if (!profile.editingAvailable) {
      notify("Editing unavailable: broker does not support capability narrowing (upgrade required).");
      return false;
    }
    if (profile.allowedManualCapabilities.length === 0) {
      notify("No manually-selectable capabilities are available to narrow for this role");
      return false;
    }
    setNarrowingScopeIndex(0);
    setNarrowingCapabilityIndex(0);
    setNarrowingPreview(null);
    setNarrowingStatus("");
    setNarrowingMode("browsing");
    notify("Narrowing editor opened");
    return true;
  }

  // Shared gate for actually beginning the kill-switch confirm flow, given an already-resolved,
  // current-role-matching profile (issue #105 PR3 completion) -- mirrors tryOpenNarrowingEditor
  // exactly: used both when a profile is already loaded (immediate open) and when a queued 'k'
  // press (see pendingKillSwitchGeneration) resolves. Never invoked with a stale/superseded/absent
  // profile -- callers only reach this once their own generation guard has already confirmed the
  // profile is current, so editingAvailable is always a real, known value here, never defaulted.
  function tryOpenKillSwitchConfirm(profile: CapabilityProfile): boolean {
    if (!profile.editingAvailable) {
      // Legacy broker (issue #105 PR3 review): the kill switch was introduced in the same release
      // as narrowing, so a broker too old to report editingAvailable=true cannot support it either
      // -- stays read-only/upgrade-required, exactly like the narrowing editor.
      setSettingsStatus("Unavailable: broker does not support capability narrowing (upgrade required).");
      return false;
    }
    setKillSwitchStage("confirm");
    return true;
  }

  function openNarrowingEditor(): void {
    if (!props.broker) {
      // Rendered the same way as refreshSettingsProfile's own broker-not-connected message
      // (a persistent line inside the Settings overlay) rather than the transient global STATUS
      // toast: the Settings overlay itself covers most of the screen including that global bar,
      // so a notify()-only message here would be clipped by the very panel it's meant to explain.
      if (overlay() !== "settings") setOverlay("settings");
      setSettingsProfile(null);
      setSettingsStatus("Observe-only: trusted manual broker is unavailable");
      return;
    }
    const loaded = settingsDisplayProfile();
    if (loaded) {
      tryOpenNarrowingEditor(loaded);
      return;
    }
    if (!historyCurrent()) {
      if (overlay() !== "settings") setOverlay("settings");
      setSettingsStatus("Unavailable: select a retained PR history row to resolve a next-launch profile.");
      return;
    }
    // First use / role-switch race (issue #105 PR3 review): no profile has resolved for the
    // current role yet (e.g. the command palette's edit entry was picked before Settings had ever
    // been opened). Queue the open against refreshSettingsProfile's own generation token instead
    // of dropping it, double-fetching, or opening a stale/empty editor -- it fires automatically
    // once that in-flight (or freshly-triggered) load resolves; see the pendingNarrowingEditorGeneration
    // consumers in refreshSettingsProfile and the clear in closeSettings.
    if (overlay() !== "settings") openSettings();
    else if (!settingsRefreshPending) void refreshSettingsProfile(settingsRole());
    pendingNarrowingEditorGeneration = settingsGeneration;
    notify("Narrowing editor will open once the effective profile finishes loading");
  }

  function cancelNarrowingEdit(): void {
    narrowingGeneration += 1;
    setNarrowingMode("browsing");
    setNarrowingPreview(null);
    setNarrowingStatus("");
  }

  function closeNarrowingEditor(): void {
    narrowingGeneration += 1;
    setNarrowingMode(null);
    setNarrowingPreview(null);
    setNarrowingStatus("");
  }

  // Fail-closed UI (issue #105 PR3 review): the broker rejects preview/apply-narrowing with this
  // distinct code when the kill switch became active concurrently (e.g. another operator enabled
  // it while this preview was already in flight). The editor can never apply anything in that
  // state, so callers exit back to the read-only profile view instead of leaving the user stuck.
  function isKillSwitchActiveRejection(error: unknown): error is BrokerRejectionError {
    return error instanceof BrokerRejectionError && error.code === "narrowing-kill-switch-active";
  }

  async function previewNarrowing(action: NarrowingAction): Promise<void> {
    const entry = historyCurrent();
    if (!props.broker || !entry || narrowingMode() !== "browsing") return;
    const capabilities = narrowingCapabilities();
    const capability = capabilities[narrowingCapabilityIndex()];
    const scope = NARROWING_SCOPES[narrowingScopeIndex()];
    if (!capability || !scope) return;
    setNarrowingMode("previewing");
    setNarrowingStatus("Resolving preview...");
    const requestId = (narrowingGeneration += 1);
    try {
      const preview = await props.broker.previewNarrowing(
        entry.repositoryIdentity.key, entry.pullRequestId, settingsRole(), scope, capability, action,
      );
      if (requestId !== narrowingGeneration) return; // superseded: editor cancelled/closed meanwhile
      setNarrowingPreview(preview);
      setNarrowingMode("confirm");
      setNarrowingStatus("");
    } catch (error) {
      if (requestId !== narrowingGeneration) return;
      if (isKillSwitchActiveRejection(error)) {
        closeNarrowingEditor();
        setSettingsStatus(dispatchResultDetail(error.code, error.detail));
        void refreshSettingsProfile(settingsRole(), { silent: true });
        return;
      }
      setNarrowingStatus(error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
      setNarrowingMode("browsing");
    }
  }

  async function applyNarrowing(): Promise<void> {
    const entry = historyCurrent();
    const preview = narrowingPreview();
    if (!props.broker || !entry || !preview || narrowingMode() !== "confirm-final") return;
    setNarrowingMode("applying");
    setNarrowingStatus("");
    const requestId = (narrowingGeneration += 1);
    try {
      await props.broker.applyNarrowing(preview, entry.repositoryIdentity.key, entry.pullRequestId);
      if (requestId !== narrowingGeneration) return;
      setNarrowingStatus(`Applied: ${preview.capability} ${preview.action === "off" ? "turned off" : "reset to inherit"} at ${preview.scope} scope.`);
      setNarrowingPreview(null);
      // Refresh via the existing side-effect-free profile() RPC (never the mutating response
      // itself) -- reuses refreshSettingsProfile's own generation guard, so a stale response can
      // never render either. Awaited BEFORE flipping to "result" (issue #105 PR3 completion) so
      // the result screen's Enabled/Denied recap can never render a moment of stale, pre-apply
      // data before catching up: the refreshed profile is already in hand the instant "result"
      // first renders.
      await refreshSettingsProfile(settingsRole(), { silent: true });
      if (requestId !== narrowingGeneration) return;
      setNarrowingMode("result");
    } catch (error) {
      if (requestId !== narrowingGeneration) return;
      if (isKillSwitchActiveRejection(error)) {
        closeNarrowingEditor();
        setSettingsStatus(dispatchResultDetail(error.code, error.detail));
        void refreshSettingsProfile(settingsRole(), { silent: true });
        return;
      }
      setNarrowingStatus(error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
      setNarrowingMode("browsing");
      setNarrowingPreview(null);
    }
  }

  // PR3 kill-switch TTL display: the emergency lever is broker-enforced short-lived (recommended
  // 1 hour), so Settings shows the operator how much of that window is left rather than leaving
  // "ON" looking permanent. now() is the existing 1s-refreshed clock signal, so this counts down
  // live while Settings stays open.
  function killSwitchExpiryLabel(profile: CapabilityProfile): string {
    if (!profile.killSwitchActive || !profile.killSwitchExpiresAtUtc) return "";
    const expiresAtMs = Date.parse(profile.killSwitchExpiresAtUtc);
    if (Number.isNaN(expiresAtMs)) return "";
    const remainingMinutes = Math.max(0, Math.ceil((expiresAtMs - now()) / 60_000));
    // Bounded like every other broker-supplied string rendered in this overlay (issue #105 PR3
    // completion) -- dispatch.ts's parser already validates/bounds this value at the wire
    // boundary, but rendering it through line() too means no single field's parser is ever the
    // only thing standing between a malformed value and unbounded terminal output.
    return ` (expires in ${remainingMinutes}m, ${line(profile.killSwitchExpiresAtUtc, 40)})`;
  }

  async function toggleKillSwitch(): Promise<void> {
    const entry = historyCurrent();
    const profile = settingsDisplayProfile();
    // Never default an unknown current state to "off" (issue #105 PR3 completion): the prior
    // `?? false` fallback meant a momentarily-null/stale profile always computed nextEnabled as
    // "turn ON", even if the switch were actually already active. tryOpenKillSwitchConfirm never
    // enters "confirm" without a current, loaded profile, and nothing between then and 'y' can
    // invalidate it without also resetting killSwitchStage to "none" (see setSettingsRole/
    // closeSettings) -- so a null profile here means that invariant broke; abort rather than guess.
    if (!props.broker || !entry || !profile) {
      setKillSwitchStage("none");
      // issue #105 PR3 closure: silently vanishing the confirm dialog here left the operator
      // guessing whether anything happened at all -- state plainly that the toggle was abandoned
      // and why, the same way every other abort/failure path in this overlay already does.
      setSettingsStatus("Kill switch toggle aborted: effective profile is no longer available.");
      return;
    }
    setKillSwitchStage("none");
    const nextEnabled = !profile.killSwitchActive;
    const role = settingsRole();
    const requestId = (killSwitchGeneration += 1);
    setSettingsStatus(nextEnabled
      ? "Enabling emergency lever: ignore local narrowing overrides..."
      : "Disabling emergency lever: ignore local narrowing overrides...");
    try {
      await props.broker.setKillSwitch(entry.repositoryIdentity.key, role, nextEnabled);
      if (requestId !== killSwitchGeneration) return; // superseded: Settings closed/re-roled meanwhile
      setSettingsStatus(nextEnabled
        ? "Ignore local narrowing overrides is now ON: persisted narrowing is ignored until the next launch."
        : "Ignore local narrowing overrides is now OFF: persisted narrowing applies again.");
      // Silent (issue #105 PR3 review): mirrors previewNarrowing()/applyNarrowingEdit()'s own
      // internal refresh -- a non-silent refresh would immediately overwrite the confirmation
      // message just set above with "Resolving effective profile..." before it was ever visible.
      void refreshSettingsProfile(role, { silent: true });
    } catch (error) {
      if (requestId !== killSwitchGeneration) return;
      setSettingsStatus(error instanceof BrokerRejectionError
        ? dispatchResultDetail(error.code, error.detail)
        : `Broker failure: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  async function quit(): Promise<void> {
    setFeedback("Shutting down broker-owned manual work...");
    bestEffortCancelWidening();
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
    {
      label: "Show effective capability profile (next launch)",
      enabled: true,
      unavailable: "",
      run: openSettings,
    },
    {
      label: "Edit persisted capability narrowing (next launch)",
      enabled: Boolean(props.broker),
      unavailable: "Observe-only: trusted manual broker is unavailable",
      run: openNarrowingEditor,
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
        // PR4 interactive widening (issue #105), nested inside "confirm": while a widening
        // sub-stage is active it owns Esc/c/y exclusively; the ordinary d/Esc confirm gate below
        // only ever sees keys once wideningStage() is back to "closed" (including right after a
        // successful mint -- see confirmWideningMintStep, which never advances manualMode itself).
        const wStage = wideningStage();
        if (wStage === "preview" || wStage === "summary") {
          if (key.name === "escape") void cancelWideningStep();
          else if (wStage === "preview" && key.name === "c") void confirmWideningPreviewStep();
          else if (wStage === "summary" && key.name === "y") void confirmWideningMintStep();
        } else if (wStage === "describing" || wStage === "confirming" || wStage === "minting" || wStage === "cancelling") {
          // A widening RPC is in flight; ignore keys until it settles rather than let d/Esc race it.
        } else if (key.name === "escape") closeManual();
        else if (key.name === "d") setManualMode("confirm-final");
        else if (key.name === "w" && canRequestWidening()) void beginWidening();
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
    if (key.name === "q") {
      void quit();
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
      } else if (key.name === "up" || key.name === "k") {
        eventScrollbox?.scrollBy({ x: 0, y: -3 });
      } else if (key.name === "down" || key.name === "j") {
        eventScrollbox?.scrollBy({ x: 0, y: 3 });
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
    if (overlay() === "settings") {
      const editing = narrowingMode();
      if (editing === "browsing") {
        const capabilityCount = narrowingCapabilities().length;
        if (key.name === "escape") closeNarrowingEditor();
        else if (key.name === "left") setNarrowingScopeIndex((v) => (v + NARROWING_SCOPES.length - 1) % NARROWING_SCOPES.length);
        else if (key.name === "right") setNarrowingScopeIndex((v) => (v + 1) % NARROWING_SCOPES.length);
        else if ((key.name === "up" || key.name === "k") && capabilityCount > 0) {
          setNarrowingCapabilityIndex((v) => (v + capabilityCount - 1) % capabilityCount);
        } else if ((key.name === "down" || key.name === "j") && capabilityCount > 0) {
          setNarrowingCapabilityIndex((v) => (v + 1) % capabilityCount);
        } else if (key.name === "o") void previewNarrowing("off");
        else if (key.name === "i") void previewNarrowing("inherit");
        return;
      }
      if (editing === "confirm") {
        if (key.name === "escape") cancelNarrowingEdit();
        else if (key.name === "c") setNarrowingMode("confirm-final");
        return;
      }
      if (editing === "confirm-final") {
        if (key.name === "escape") cancelNarrowingEdit();
        else if (key.name === "y") void applyNarrowing();
        return;
      }
      if (editing === "result") {
        if (key.name === "escape" || key.name === "return") { setNarrowingMode("browsing"); setNarrowingStatus(""); }
        return;
      }
      if (editing === "previewing" || editing === "applying") return;
      // Two-stage kill-switch confirm (issue #105 PR3 completion), mirroring narrowing's own
      // confirm/confirm-final: "confirm" is the first, full-disclosure warning (c advances to the
      // final gate); "confirm-final" is the terse final gate that actually arms 'y'. Esc cancels
      // back to the ordinary Settings view at either stage.
      if (killSwitchStage() === "confirm") {
        if (key.name === "escape") setKillSwitchStage("none");
        else if (key.name === "c") setKillSwitchStage("confirm-final");
        return;
      }
      if (killSwitchStage() === "confirm-final") {
        if (key.name === "escape") setKillSwitchStage("none");
        else if (key.name === "y") void toggleKillSwitch();
        return;
      }
      if (key.name === "escape" || key.name === "s") {
        closeSettings();
      } else if (key.name === "tab") {
        // Ignore role toggles while a describe() is outstanding (see settingsRefreshPending):
        // otherwise the label could advance to a role whose refetch never fires. The NEW role is
        // computed here and threaded straight into refreshSettingsProfile as an explicit argument
        // rather than re-read from the settingsRole() signal inside it.
        if (settingsRefreshPending) return;
        const nextRole: AgentRole = settingsRole() === "reviewer" ? "review-handler" : "reviewer";
        setSettingsRole(nextRole);
        // A role switch mid-flight invalidates any toggleKillSwitch() awaiting a response for the
        // OLD role (issue #105 PR3 completion): killSwitchStage is already reset to "none" by the
        // time 'y' is pressed (see toggleKillSwitch), so Tab can otherwise land here while that
        // await is still outstanding -- see toggleKillSwitch's own requestId guard. Reset
        // explicitly here too (issue #105 PR3 closure) rather than relying solely on that
        // invariant: the kill switch is machine+user-wide, never role-scoped, so a confirm opened
        // for one role's profile must never carry over and be actioned against another role's.
        setKillSwitchStage("none");
        killSwitchGeneration += 1;
        void refreshSettingsProfile(nextRole);
      } else if (key.name === "r") {
        if (settingsRefreshPending) return;
        void refreshSettingsProfile(settingsRole());
      } else if (key.name === "e") {
        openNarrowingEditor();
      } else if (key.name === "k") {
        // Never begin the kill-switch flow on an unknown state (issue #105 PR3 completion): the
        // previous version fell through to setKillSwitchStage("confirm") whenever `loaded` was
        // null (no profile yet, or a request outstanding) -- i.e. it defaulted an UNKNOWN
        // editingAvailable/killSwitchActive to "proceed" rather than never assuming false OR true
        // for an unresolved value. This mirrors openNarrowingEditor's own gating exactly: open
        // immediately against an already-loaded, current profile; otherwise queue the intent
        // against refreshSettingsProfile's generation token (fires once that load resolves) rather
        // than racing ahead of it or silently dropping the keypress.
        if (!props.broker) {
          setSettingsStatus("Observe-only: trusted manual broker is unavailable");
        } else if (settingsRefreshPending) {
          // issue #105 PR3 closure: a refresh already in flight means the currently loaded
          // profile (settingsDisplayProfile(), even one that still role-matches) can be stale
          // relative to it -- e.g. toggleKillSwitch's own silent refresh just kicked off after
          // applying a transition, so the last-rendered profile still reflects the PRE-transition
          // state. Never open (or decide a direction) against that stale snapshot; queue against
          // the ACTIVE generation exactly like the no-profile-yet branch below, so the confirm
          // dialog only ever opens once the fresh, matching profile actually lands (see
          // refreshSettingsProfile's pendingKillSwitchGeneration consumption) -- never repeating a
          // just-applied transition instead of its correct reverse.
          pendingKillSwitchGeneration = settingsGeneration;
          setSettingsStatus("Kill switch will open once the effective profile finishes loading.");
        } else {
          const loaded = settingsDisplayProfile();
          if (loaded) {
            tryOpenKillSwitchConfirm(loaded);
          } else if (!historyCurrent()) {
            setSettingsStatus("Unavailable: select a retained PR history row to resolve a next-launch profile.");
          } else {
            void refreshSettingsProfile(settingsRole());
            pendingKillSwitchGeneration = settingsGeneration;
            setSettingsStatus("Kill switch will open once the effective profile finishes loading.");
          }
        }
      }
      return;
    }

    if (key.name === "up" || key.name === "k") move(-1);
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
    else if (key.name === "s") openSettings();
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
              wideningStage={wideningStage()}
              wideningPreview={wideningPreview()}
              wideningStatus={wideningStatus()}
              mintedWideningGeneration={mintedWideningGeneration()}
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
          <scrollbox
            ref={(value) => { eventScrollbox = value; }}
            flexGrow={1}
            scrollY
            stickyScroll
            stickyStart="bottom"
          >
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
          <text height={1} fg={COLORS.text}>e                  Raw events; Up/Down scroll; Left/Right filter</text>
          <text height={1} fg={COLORS.text}>w                  Next attention item</text>
          <text height={1} fg={COLORS.text}>o                  Open validated http/https PR URL</text>
          <text height={1} fg={COLORS.text}>Ctrl+P             Context command palette</text>
          <text height={1} fg={COLORS.text}>m                  Manual dispatch for selected retained PR (trusted launch only)</text>
          <text height={1} fg={COLORS.text}>  (dispatch confirm) w   Request capability widening, if delegable (draft-bound)</text>
          <text height={1} fg={COLORS.text}>  (widening) c / y   Confirm preview / mint the grant | Esc cancels widening</text>
          <text height={1} fg={COLORS.text}>s                  Effective capability profile for the next manual launch</text>
          <text height={1} fg={COLORS.text}>  (in Settings) e   Edit persisted narrowing | k toggle kill switch</text>
          <text height={1} fg={COLORS.text}>?                  Help</text>
          <text height={1} fg={COLORS.text}>q                  Quit</text>
          <text height={1} fg={COLORS.muted}>{HELP_LEGEND[0]}</text>
          <text height={1} fg={COLORS.muted}>{HELP_LEGEND[1]}</text>
          <text height={1} fg={COLORS.warning}>{HELP_LEGEND[2]}</text>
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "settings"}>
        <OverlayPanel
          title={narrowingMode() ? "SETTINGS - EDIT PERSISTED NARROWING" : "SETTINGS - EFFECTIVE CAPABILITY PROFILE"}
          left="0%"
          padding={0}
          width={142}
          height={27}
        >
          <box flexDirection="column" flexGrow={1}>
            <text height={1} fg={COLORS.warning}>Applies only to the next manual dispatch/process launch.</text>
            <text height={1} fg={COLORS.warning}>A running agent's own profile is immutable and is not shown here.</text>
            <Show when={!narrowingMode()}>
              <text height={1} fg={COLORS.text}>
                Role: {roleLabel(settingsRole())} | Tab role | r refresh | e edit narrowing | k kill switch | Esc/s close
              </text>
            </Show>
            <Show when={settingsStatus()}>
              <text height={1} fg={COLORS.warning}>{line(settingsStatus(), 170)}</text>
            </Show>
            {/* Two-stage kill-switch confirm (issue #105 PR3 completion). "confirm" (first
                warning) carries the full disclosure required for the ENABLE direction: this is a
                machine+user-wide lever across every repo/worktree/PR for this user, it ignores
                persisted narrowing and restores compiled operational defaults for NEXT launches
                only, an already-running agent is immutable/unaffected, and it grants no delegated
                approval-vote/auto-complete. The DISABLE direction's blast radius is much smaller
                (persisted narrowing simply applies again), so its first-stage wording stays terse,
                matching the narrowing editor's own confirm/confirm-final asymmetry (full detail on
                the first stage, a short recap+action on the final one). */}
            <Show when={killSwitchStage() === "confirm"}>
              <Show
                when={!(settingsDisplayProfile()?.killSwitchActive ?? false)}
                fallback={
                  <>
                    <text height={1} fg={COLORS.error}>
                      {line("Disable 'Ignore local narrowing overrides'? Persisted narrowing becomes active again for next launches.", 170)}
                    </text>
                    <text height={1} fg={COLORS.error}>
                      {line("Press c to review the final confirmation; Esc cancels.", 170)}
                    </text>
                  </>
                }
              >
                <text height={1} fg={COLORS.error}>
                  {line("WARNING: machine+user-wide emergency lever -- affects ALL repos/worktrees/PRs for this user on this machine, not just this PR.", 170)}
                </text>
                <text height={1} fg={COLORS.error}>
                  {line("Ignores all locally persisted narrowing; restores compiled operational defaults for NEXT launches only.", 170)}
                </text>
                <text height={1} fg={COLORS.error}>
                  {line("Any already-running agent is immutable and unaffected; grants no delegated approval-vote or auto-complete.", 170)}
                </text>
                <text height={1} fg={COLORS.warning}>
                  {line("Press c to review the final confirmation; Esc cancels.", 170)}
                </text>
              </Show>
            </Show>
            <Show when={killSwitchStage() === "confirm-final"}>
              <Show
                when={!(settingsDisplayProfile()?.killSwitchActive ?? false)}
                fallback={
                  <>
                    <text height={1} fg={COLORS.error}>
                      {line("FINAL CONFIRMATION: disable 'Ignore local narrowing overrides'? Persisted narrowing becomes active again.", 170)}
                    </text>
                    <text height={1} fg={COLORS.error}>{line("Press y to disable; Esc cancels.", 170)}</text>
                  </>
                }
              >
                <text height={1} fg={COLORS.error}>
                  {line("FINAL CONFIRMATION: enable the kill switch machine+user-wide across ALL repos/worktrees/PRs?", 170)}
                </text>
                <text height={1} fg={COLORS.error}>{line("Press y to enable; Esc cancels.", 170)}</text>
              </Show>
            </Show>
            <Show when={narrowingMode() && narrowingMode() !== "result" && narrowingStatus()}>
              <text height={1} fg={COLORS.warning}>{line(narrowingStatus(), 170)}</text>
            </Show>
            {/* Operand order matters here: Show's render-prop accessor receives the resolved
                `when` VALUE, and `&&` returns its right-hand operand when the left is truthy. With
                the guard first and the profile second, a truthy result is always the profile
                object itself -- never the boolean from `!narrowingMode()` -- so the accessor below
                can never observe a boxed boolean where a CapabilityProfile is expected (the prior
                `profile && !narrowingMode()` ordering crashed with "undefined is not an object"
                inside profile().repositoryIdentity.slug once narrowingMode() was falsy). */}
            <Show when={!narrowingMode() && settingsDisplayProfile()}>
              {(profile: () => CapabilityProfile) => (
                <>
                  <text height={1} fg={COLORS.accent}>{profile().repositoryIdentity.slug} / PR #{profile().prSnapshot.pullRequestId}</text>
                  <text height={1} fg={profile().killSwitchActive ? COLORS.error : COLORS.muted}>
                    Ignore local narrowing overrides: {!profile().editingAvailable
                      ? "unavailable (upgrade required)"
                      : profile().killSwitchActive
                        ? `ON (emergency lever, not a security lockdown)${killSwitchExpiryLabel(profile())}`
                        : "off"}
                  </text>
                  <text height={1} fg={COLORS.ok}>Enabled for this launch: {line(profile().capabilities.join(", ") || "none", 110)}</text>
                  <text height={1} fg={COLORS.warning}>Denied (mandatory): {line(profile().mandatoryDenies.join(", ") || "none", 110)}</text>
                  {/* Legacy-broker fallback (issue #105 PR3 completion): allowedManualCapabilities/
                      absoluteDenies/delegableAvailable/provenance are all optional-defaulted to
                      empty on a pre-narrowing broker (dispatch.ts's parseCapabilityProfileFields),
                      the same signal editingAvailable itself is computed from. Rendering those
                      defaults as "none"/"none in this release" would fabricate a locked-down,
                      fully-resolved profile the broker never actually reported -- so a legacy
                      broker gets one explicit "unavailable" line instead of four fabricated ones. */}
                  <Show
                    when={profile().editingAvailable}
                    fallback={
                      <text height={1} fg={COLORS.warning}>
                        Allowed manual ceiling / absolute denies / delegable available / provenance: unavailable (broker predates capability narrowing; upgrade required).
                      </text>
                    }
                  >
                    <text height={1} fg={COLORS.ok}>Allowed manual ceiling: {line(profile().allowedManualCapabilities.join(", ") || "none", 110)}</text>
                    <text height={1} fg={COLORS.error}>Absolute denies (never grantable, locked): {line(profile().absoluteDenies.join(", ") || "none", 110)}</text>
                    <text height={1} fg={COLORS.muted}>Delegable available (widening, locked here): {line(profile().delegableAvailable.join(", ") || "none in this release", 110)}</text>
                    <text height={1} fg={COLORS.muted}>
                      Provenance: {line(Object.entries(profile().provenance).map(([name, source]) => `${name}=${source}`).join(", ") || "none", 170)}
                    </text>
                  </Show>
                </>
              )}
            </Show>
            <Show when={narrowingMode() === "browsing"}>
              <box flexDirection="column">
                <text height={1} fg={COLORS.text}>
                  Scope: {NARROWING_SCOPES.map((scopeName, index) => index === narrowingScopeIndex() ? `[${scopeName}]` : scopeName).join("  ")}
                  {" "}(Left/Right change)
                </text>
                <text height={1} fg={COLORS.muted}>Up/Down select capability | o narrow (off) | i reset (inherit) | Esc cancel</text>
                <For each={narrowingCapabilities()}>
                  {(name, index) => (
                    <text height={1} fg={index() === narrowingCapabilityIndex() ? COLORS.accent : COLORS.text}>
                      {index() === narrowingCapabilityIndex() ? "> " : "  "}{name}
                    </text>
                  )}
                </For>
              </box>
            </Show>
            <Show when={narrowingMode() === "previewing" || narrowingMode() === "applying"}>
              <text height={1} fg={COLORS.warning}>{narrowingMode() === "previewing" ? "Resolving preview..." : "Applying..."}</text>
            </Show>
            <Show when={narrowingPreview()}>
              {(preview: () => CapabilityNarrowingPreview) => (
                <box flexDirection="column">
                  <text height={1} fg={COLORS.accent}>
                    {preview().scope} / {preview().capability} -&gt; {preview().action === "off" ? "off" : "inherit"}
                    {preview().killSwitchActive ? " (kill switch ON: no effect until disabled)" : ""}
                  </text>
                  <text height={1} fg={preview().changed ? COLORS.warning : COLORS.muted}>
                    {preview().changed ? "This changes the effective profile:" : "No effective change (another scope already decides this)."}
                  </text>
                  <text height={1} fg={COLORS.text}>Current enabled: {line(preview().current.capabilities.join(", ") || "none", 100)}</text>
                  <text height={1} fg={COLORS.text}>Proposed enabled: {line(preview().proposed.capabilities.join(", ") || "none", 100)}</text>
                  <text height={1} fg={COLORS.warning}>Current denied: {line(preview().current.mandatoryDenies.join(", ") || "none", 100)}</text>
                  <text height={1} fg={COLORS.warning}>Proposed denied: {line(preview().proposed.mandatoryDenies.join(", ") || "none", 100)}</text>
                  <Show when={narrowingMode() === "confirm"}>
                    <text height={1} fg={COLORS.warning}>First confirmation: press c to review the final apply gate; Esc cancels.</text>
                  </Show>
                  <Show when={narrowingMode() === "confirm-final"}>
                    <text height={1} fg={COLORS.error}>FINAL CONFIRMATION: press y to apply this exact preview; Esc cancels.</text>
                  </Show>
                </box>
              )}
            </Show>
            <Show when={narrowingMode() === "result"}>
              <text height={1} fg={COLORS.ok}>{line(narrowingStatus(), 170)} (Esc/Enter back)</text>
              {/* issue #105 PR3 completion: the result screen must show the REFRESHED effective
                  profile, not just the "Applied: ..." status line -- applyNarrowing() now awaits
                  refreshSettingsProfile() before ever entering "result", so
                  settingsDisplayProfile() is already the post-apply truth the first time this
                  renders (never a stale pre-apply snapshot). */}
              <Show when={settingsDisplayProfile()}>
                {(profile: () => CapabilityProfile) => (
                  <>
                    <text height={1} fg={COLORS.ok}>Enabled: {line(profile().capabilities.join(", ") || "none", 110)}</text>
                    <text height={1} fg={COLORS.warning}>Denied (mandatory): {line(profile().mandatoryDenies.join(", ") || "none", 110)}</text>
                  </>
                )}
              </Show>
            </Show>
          </box>
        </OverlayPanel>
      </Show>
    </box>
  );
}
