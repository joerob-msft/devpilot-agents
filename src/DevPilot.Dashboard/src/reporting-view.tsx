import { Index, Show } from "solid-js";
import type { ScrollBoxRenderable } from "@opentui/core";
import type {
  DeliverySummary,
  FailureSummary,
  FindingSummary,
  RelationSummary,
  ReportingSnapshot,
  RunSummary,
} from "./reporting.js";

export const REPORTING_SECTIONS = [
  "overview", "runs", "findings", "deliveries", "failures", "relations",
] as const;
export type ReportingSection = (typeof REPORTING_SECTIONS)[number];
export type ReportingTimeRange = "24h" | "7d" | "30d" | "all";
export type ReportingPostingFilter = "all" | "pending" | "posted";
export type ReportingModeFilter = "all" | "automatic" | "manual";

export interface ReportingFilters {
  timeRange: ReportingTimeRange;
  search: string;
  posting: ReportingPostingFilter;
  mode: ReportingModeFilter;
}

export interface ReportingRow {
  key: string;
  timestamp: string;
  pullRequestId: number;
  capability: string;
  health: string;
  outcome: string;
  posting: "pending" | "posted" | "none";
  mode: "automatic" | "manual" | "none";
  text: string[];
  searchText: string;
  url: string | null;
  attention: boolean;
}

export interface ReportingColors {
  panel: string;
  panelAlt: string;
  border: string;
  accent: string;
  text: string;
  muted: string;
  warning: string;
  ok: string;
  error: string;
}

const clean = (value: unknown, max = 240): string =>
  typeof value === "string"
    ? value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, " ")
      .replace(/\s+/g, " ").trim().slice(0, max)
    : "";

const exactDisplayBody = (value: unknown): string | null => {
  if (typeof value !== "string" || value.length > 4_096 ||
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\r]/.test(value)) return null;
  return value;
};

const shortCommit = (value: string): string => value ? value.slice(0, 12) : "unknown";

function ageText(value: number | null): string {
  if (value === null) return "unknown";
  if (value < 60) return `${value}m`;
  if (value < 1_440) return `${Math.floor(value / 60)}h ${value % 60}m`;
  return `${Math.floor(value / 1_440)}d ${Math.floor((value % 1_440) / 60)}h`;
}

function queryTokens(search: string): {
  text: string[];
  pr: number | null;
  capability: string;
  health: string;
  outcome: string;
} {
  const result = { text: [] as string[], pr: null as number | null, capability: "", health: "", outcome: "" };
  for (const token of search.trim().split(/\s+/).filter(Boolean)) {
    const [prefix, ...rest] = token.split(":");
    const value = rest.join(":").toLowerCase();
    if (prefix?.toLowerCase() === "pr" && /^[1-9][0-9]*$/.test(value)) result.pr = Number(value);
    else if (prefix?.toLowerCase() === "capability") result.capability = value;
    else if (prefix?.toLowerCase() === "health") result.health = value;
    else if (prefix?.toLowerCase() === "outcome") result.outcome = value;
    else result.text.push(token.toLowerCase());
  }
  return result;
}

function rangeStart(range: ReportingTimeRange, now: number): number {
  if (range === "all") return Number.NEGATIVE_INFINITY;
  const hours = range === "24h" ? 24 : range === "7d" ? 24 * 7 : 24 * 30;
  return now - hours * 60 * 60 * 1_000;
}

export function filterReportingRows(
  rows: ReportingRow[],
  filters: ReportingFilters,
  now = Date.now(),
): ReportingRow[] {
  const query = queryTokens(filters.search);
  const start = rangeStart(filters.timeRange, now);
  return rows.filter((row) => {
    const timestamp = Date.parse(row.timestamp);
    if (Number.isFinite(timestamp) && timestamp < start) return false;
    if (query.pr !== null && row.pullRequestId !== query.pr) return false;
    if (query.capability && !row.capability.toLowerCase().includes(query.capability)) return false;
    if (query.health && !row.health.toLowerCase().includes(query.health)) return false;
    if (query.outcome && !row.outcome.toLowerCase().includes(query.outcome)) return false;
    if (filters.posting !== "all" && row.posting !== filters.posting) return false;
    if (filters.mode !== "all" && row.mode !== filters.mode) return false;
    return query.text.every((token) => row.searchText.includes(token));
  });
}

function runRow(run: RunSummary): ReportingRow {
  const coverage = run.deliveryCapabilityId === "bpm-test-class-coverage@1";
  const text = [
    `${run.occurredUtc || "time unavailable"} | ${run.health} | run ${run.runId}`,
    `${coverage ? "Coverage" : "Owner"} ${run.ownerCompleted} completed / ${run.ownerFailed} failed | Relation ${run.relationCompleted} completed / ${run.relationFailed} failed`,
    `Attempts ${run.attempts} | model calls ${run.modelCalls ?? "unknown"} | queue pending ${run.queuePending} / posted ${run.queuePosted}`,
    `Provider writes ${run.providerWrites} | model writes ${run.modelWrites} | delivery ${run.deliveryOutcome}`,
    ...(run.durationMilliseconds === null ? [] : [`Duration ${run.durationMilliseconds} ms`]),
    ...(run.diagnostic ? [`Diagnostic: ${run.diagnostic}`] : []),
  ];
  return {
    key: `run:${run.runId}:${run.occurredUtc}`, timestamp: run.occurredUtc,
    pullRequestId: 0, capability: run.deliveryCapabilityId ?? "owner", health: run.health, outcome: run.deliveryOutcome,
    posting: run.queuePending > 0 ? "pending" : run.queuePosted > 0 ? "posted" : "none",
    mode: "automatic", text,
    searchText: clean(text.join(" ")).toLowerCase(), url: null,
    attention: /partial|refused|fail|error|unknown/i.test(`${run.health} ${run.deliveryOutcome} ${run.diagnostic}`),
  };
}

function findingRow(finding: FindingSummary): ReportingRow {
  const needsReview = finding.state === "humanCovered" ||
    (finding.capability === "bpm-test-class-coverage@1" &&
      finding.state === "unknown" &&
      finding.reason === "historical-human-review-needs-review");
  const text = [
    `PR #${finding.pullRequestId} | ${finding.severity} | ${needsReview ? `${finding.state} (needs-review)` : finding.state} | ${finding.capability}`,
    `${finding.path || "path unavailable"}:${finding.line || "?"} | ${finding.symbol || "symbol unavailable"}`,
    `Rule: ${finding.rule || "unavailable"} | source ${shortCommit(finding.sourceCommit)} (${finding.sourceFreshness})`,
    `Reason: ${finding.reason || "unavailable"}`,
  ];
  return {
    key: `finding:${finding.id}`, timestamp: finding.updatedUtc,
    pullRequestId: finding.pullRequestId, capability: finding.capability,
    health: needsReview ? "needs-review" :
      finding.sourceFreshness === "stale" || finding.state === "unknown" ? "degraded" : "healthy",
    outcome: finding.state, posting: finding.state === "noOp" ? "posted" : "pending",
    mode: "none", text, searchText: clean(text.join(" ")).toLowerCase(), url: finding.url,
    attention: finding.sourceFreshness === "stale" || finding.state === "unknown" || needsReview,
  };
}

function deliveryRow(delivery: DeliverySummary): ReportingRow {
  const needsReview = delivery.capabilityId === "bpm-test-class-coverage@1" &&
    delivery.action === "none" && delivery.outcome === "refused" &&
    delivery.diagnosticCode === "historical-human-review-needs-review";
  const verifiedBody = delivery.bodyStatus === "verified" ? exactDisplayBody(delivery.body) : null;
  const body = verifiedBody !== null
    ? verifiedBody
    : delivery.bodySha256
      ? `Body unavailable; verified digest ${delivery.bodySha256}`
      : "Body unavailable; no locally bound digest.";
  const text = [
    `PR #${delivery.pullRequestId} | ${delivery.mode} ${delivery.action} | ${needsReview ? "refused (needs-review)" : delivery.outcome} | ${delivery.capabilityId}`,
    `${delivery.path || "path unavailable"}:${delivery.line || "?"} | ${delivery.symbol || "symbol unavailable"}`,
    `Rule: ${delivery.rule || "unavailable"}`,
    `Thread ${delivery.threadId ?? "n/a"} / comment ${delivery.commentId ?? "n/a"} | write ${delivery.providerWriteState}`,
    `Run ${delivery.runId || "n/a"}${delivery.eventId ? ` | event ${delivery.eventId}` : ""}`,
    body,
    ...(delivery.diagnostic ? [`Diagnostic: ${delivery.diagnosticCode ? `${delivery.diagnosticCode}: ` : ""}${delivery.diagnostic}`] : []),
    ...(delivery.commentUrl || delivery.prUrl ? [`Link: ${delivery.commentUrl ?? delivery.prUrl}`] : ["Link unavailable: identity or target was not safely validated."]),
  ];
  return {
    key: delivery.id, timestamp: delivery.occurredUtc,
    pullRequestId: delivery.pullRequestId, capability: delivery.capabilityId,
    health: needsReview ? "needs-review" :
      /ambiguous|refused|failed|unknown/i.test(`${delivery.outcome} ${delivery.providerWriteState}`) ? "degraded" : "healthy",
    outcome: delivery.outcome,
    posting: delivery.providerWrites > 0 || /created|updated|recovered|noOp/i.test(delivery.outcome) ? "posted" : "pending",
    mode: delivery.mode, text,
    searchText: clean(text.join(" ")).toLowerCase(), url: delivery.commentUrl ?? delivery.prUrl,
    attention: /ambiguous|refused|failed|unknown/i.test(`${delivery.outcome} ${delivery.providerWriteState}`),
  };
}

function failureRow(failure: FailureSummary): ReportingRow {
  const text = [
    `${failure.occurredUtc || "time unavailable"} | ${failure.category} | ${failure.health}`,
    `${failure.pullRequestId ? `PR #${failure.pullRequestId}` : "Service"}${failure.runId ? ` | run ${failure.runId}` : ""}`,
    failure.message,
  ];
  return {
    key: failure.id, timestamp: failure.occurredUtc,
    pullRequestId: failure.pullRequestId, capability: "owner",
    health: failure.health, outcome: failure.category,
    posting: failure.category === "ambiguous-write" || failure.category === "recovery-needed" ? "pending" : "none",
    mode: "none", text, searchText: clean(text.join(" ")).toLowerCase(), url: null, attention: true,
  };
}

function relationRow(relation: RelationSummary): ReportingRow {
  const text = [
    `PR #${relation.pullRequestId} | ${relation.state} | ${relation.capability}`,
    `${relation.path || "path unavailable"}:${relation.line || "?"} | ${relation.symbol || "symbol unavailable"}`,
    `Rule: ${relation.rule || "unavailable"}`,
    `Reason: ${relation.reason || "unavailable"}`,
    "READ ONLY / NOT WRITER ELIGIBLE",
  ];
  return {
    key: `relation:${relation.id}`, timestamp: relation.updatedUtc,
    pullRequestId: relation.pullRequestId, capability: relation.capability,
    health: relation.state === "unknown" ? "degraded" : "healthy", outcome: relation.state,
    posting: "none", mode: "none", text, searchText: clean(text.join(" ")).toLowerCase(),
    url: relation.url, attention: relation.state === "unknown",
  };
}

export function reportingRows(snapshot: ReportingSnapshot, section: ReportingSection): ReportingRow[] {
  if (section === "runs") return snapshot.runs.map(runRow);
  if (section === "findings") return snapshot.findings.map(findingRow);
  if (section === "deliveries") return snapshot.deliveries.map(deliveryRow);
  if (section === "failures") return snapshot.failures.map(failureRow);
  if (section === "relations") return snapshot.relations.map(relationRow);
  return [];
}

export function overviewLines(snapshot: ReportingSnapshot): string[] {
  const toolkit = snapshot.toolkit;
  const task = snapshot.task;
  return [
    `SERVICE ${snapshot.overall.status.toUpperCase()} | ${snapshot.overall.reason}`,
    `Last successful run: ${snapshot.overall.lastSuccessfulRunUtc ?? "unavailable"} (${ageText(snapshot.overall.lastSuccessfulRunAgeMinutes)} ago)`,
    `Next run: ${snapshot.overall.nextRunUtc ?? "unavailable"} | data timestamp: ${snapshot.dataTimestampUtc ?? "unavailable"}`,
    `Task: ${task.available ? task.enabled ? task.state : "disabled" : "unavailable"} | result ${task.lastResult ?? "n/a"} | ${task.diagnostic || "no diagnostic"}`,
    `Toolkit actual ${shortCommit(toolkit.actualHead)} / ${shortCommit(toolkit.actualTree)} | expected ${shortCommit(toolkit.expectedHead)} / ${shortCommit(toolkit.expectedTree)}`,
    `Toolkit binding: ${toolkit.matches === null ? "not configured" : toolkit.matches ? "match" : "MISMATCH"} | automatic policy ${toolkit.automaticEnabled === null ? "unknown" : toolkit.automaticEnabled ? "enabled" : "disabled"}`,
    `Policy ${toolkit.policyId || "unavailable"} | caps run ${toolkit.maxCreatesPerRun ?? "?"} / PR ${toolkit.maxCreatesPerPullRequest ?? "?"}`,
    `Writes: provider ${snapshot.overall.providerWrites} | model ${snapshot.overall.modelWrites}`,
    `Runs ${snapshot.runs.length} | findings ${snapshot.findings.length} | deliveries ${snapshot.deliveries.length} | failures ${snapshot.failures.length}`,
    `Relation findings ${snapshot.relations.length} (read-only) | quarantine ${snapshot.quarantine.length}${snapshot.truncated ? " | HISTORY TRUNCATED BY BUDGET" : ""}`,
    ...(snapshot.diagnostics.length ? snapshot.diagnostics.map((diagnostic) => `Missing/unavailable: ${diagnostic}`) : []),
  ];
}

export function ReportingView(props: {
  snapshot: ReportingSnapshot | null;
  error: string;
  refreshing: boolean;
  actionStatus: { message: string; error: boolean } | null;
  section: ReportingSection;
  filters: ReportingFilters;
  rows: ReportingRow[];
  selected: number;
  colors: ReportingColors;
  scrollRef: (value: ScrollBoxRenderable) => void;
}) {
  const selectedRow = () => props.rows[props.selected];
  const windowStart = () => Math.max(0, props.selected);
  const visibleRows = () => props.rows.slice(windowStart(), windowStart() + 100);
  return (
    <box flexDirection="column" flexGrow={1} minHeight={0}>
      <text flexShrink={0} fg={props.colors.accent}>
        {REPORTING_SECTIONS.map((section) => section === props.section ? `[${section.toUpperCase()}]` : section).join("  ")}
      </text>
      <text flexShrink={0} fg={props.colors.muted}>
        Range {props.filters.timeRange} | posting {props.filters.posting} | mode {props.filters.mode} | search {props.filters.search || "(none)"}
      </text>
      <Show when={props.actionStatus}>
        {(status: () => { message: string; error: boolean }) => <text flexShrink={0} wrapMode="word"
          fg={status().error ? props.colors.error : props.colors.ok}>{status().message}</text>}
      </Show>
      <Show when={props.section !== "overview" && props.rows.length > 0}>
        <text flexShrink={0} fg={props.colors.muted}>
          Showing {windowStart() + 1}-{Math.min(props.rows.length, windowStart() + visibleRows().length)} of {props.rows.length}
        </text>
      </Show>
      <Show when={props.refreshing}><text flexShrink={0} fg={props.colors.warning}>Refreshing verified local state...</text></Show>
      <Show when={props.error}><text flexShrink={0} fg={props.colors.error}>Reporting unavailable: {clean(props.error, 300)}</text></Show>
      <Show when={props.snapshot} fallback={<text flexShrink={0} fg={props.colors.muted}>No reporting snapshot loaded.</text>}>
        {(snapshot: () => ReportingSnapshot) => (
          <scrollbox ref={props.scrollRef} flexGrow={1} minHeight={0} scrollY>
            <Show when={props.section === "overview"} fallback={
              <Index each={visibleRows()} fallback={<text flexShrink={0} fg={props.colors.muted}>No rows match the current filters.</text>}>
                {(row, index) => (
                  <box flexDirection="column" flexShrink={0} marginBottom={1}
                    backgroundColor={index + windowStart() === props.selected ? props.colors.panelAlt : props.colors.panel}>
                    <Index each={row().text}>
                      {(text, lineIndex) => (
                        <text flexShrink={0} wrapMode="word"
                          fg={row().attention ? props.colors.warning : lineIndex === 0 ? props.colors.accent : props.colors.text}>
                          {lineIndex === 0 ? index + windowStart() === props.selected ? "> " : "  " : "    "}{text()}
                        </text>
                      )}
                    </Index>
                  </box>
                )}
              </Index>
            }>
              <Index each={overviewLines(snapshot())}>
                {(text, index) => <text flexShrink={0} wrapMode="word"
                  fg={index === 0
                    ? snapshot().overall.status === "healthy" ? props.colors.ok
                      : snapshot().overall.status === "disabled" ? props.colors.muted : props.colors.warning
                    : props.colors.text}>{text()}</text>}
              </Index>
            </Show>
            <Show when={selectedRow()?.url}>
              <text flexShrink={0} fg={props.colors.accent}>Press o to open the selected validated Azure DevOps link.</text>
            </Show>
          </scrollbox>
        )}
      </Show>
    </box>
  );
}
