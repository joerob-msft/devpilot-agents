import type {
  DeliverySummary, FindingSummary, ReportingSnapshot, RunSummary,
} from "./reporting.js";

export type RuleStatus = "verified" | "not-deployed" | "disabled" | "stale" | "unknown";
export type PublishingStatus = "enabled" | "disabled" | "not-eligible" | "unknown";

export interface RuleEvidence {
  identity: string;
  capabilityId: string;
  ruleId: string;
  pullRequestId: number;
  evaluatedUtc: string;
  findingIds: string[];
  findings: number;
  noOp: number;
  wouldCreate: number;
  unknown: number;
}

export interface RuleOutcomeCounts {
  finding: number | null;
  noOp: number | null;
  wouldCreate: number | null;
  unknown: number | null;
  skipped: number | null;
  refused: number | null;
  posted: number | null;
}

export interface RuleSummary {
  id: string;
  sourceRuleId: string | null;
  description: string;
  provenance: string;
  implementationVersion: string;
  installedHead: string | null;
  pinnedHead: string | null;
  capabilityId: string;
  implemented: true;
  deployment: RuleStatus;
  enablement: RuleStatus;
  execution: RuleStatus;
  authorization: PublishingStatus;
  publishing: PublishingStatus;
  policyCaps: { perRun: number; perPullRequest: number } | null;
  scope: number[];
  lastGeneration: string | null;
  lastEvaluatedUtc: string | null;
  counts: RuleOutcomeCounts;
  findingIds: string[];
  deliveryIds: string[];
  url: string | null;
  gaps: string[];
}

interface RuleDefinition {
  id: string;
  description: string;
  provenance: string;
  implementationVersion: string;
  capabilityId: string;
  runChannel: "owner" | "relation" | "coverage";
}

// Source inventory is not an installation or deployment manifest.
export const IMPLEMENTED_RULES: readonly RuleDefinition[] = [
  {
    id: "mstest-owner",
    description: "Changed MSTest methods require an Owner attribute.",
    provenance: "Owner service cohort PR 17109075 (operator-reported; installed head must be verified)",
    implementationVersion: "bpm-test-ownership@1",
    capabilityId: "bpm-test-ownership@1",
    runChannel: "owner",
  },
  {
    id: "relation-contextual-review-v1",
    description: "Relation evidence on changed PRs; read-only, never writer eligible.",
    provenance: "Relation service cohort PR 16950415 (operator-reported; installed head must be verified)",
    implementationVersion: "relation-contextual-review-v1",
    capabilityId: "relation-contextual-review-v1",
    runChannel: "relation",
  },
  {
    id: "bpm-test-class-coverage@1",
    description: "Changed MSTest classes require [ExcludeFromCodeCoverage]; default off.",
    provenance: "PR 174 source 588c0045e24542d10a76bbfadc6e6d1aa2c4c528; not in pinned PR 173 service",
    implementationVersion: "588c0045e24542d10a76bbfadc6e6d1aa2c4c528",
    capabilityId: "bpm-test-class-coverage@1",
    runChannel: "coverage",
  },
];

function runIdentities(run: RunSummary, channel: RuleDefinition["runChannel"]): string[] {
  if (channel === "relation") return run.relationStateIdentities ?? [];
  if (channel === "coverage" && run.deliveryCapabilityId !== "bpm-test-class-coverage@1") return [];
  if (channel === "owner" && run.deliveryCapabilityId === "bpm-test-class-coverage@1") return [];
  return run.ownerStateIdentities ?? [];
}

function matchingDelivery(
  delivery: DeliverySummary, definition: RuleDefinition, evidence: RuleEvidence[],
): boolean {
  return delivery.capabilityId === definition.capabilityId &&
    evidence.some((state) => state.pullRequestId === delivery.pullRequestId &&
      state.findingIds.includes(delivery.findingId ?? "") &&
      (definition.runChannel !== "coverage" || delivery.rule === definition.id));
}

export function projectRuleRegistry(
  snapshot: Pick<ReportingSnapshot, "generatedAtUtc" | "task" | "toolkit" | "runs" |
    "findings" | "relations" | "deliveries" | "failures" | "quarantine" | "diagnostics" | "truncated">,
  evidence: RuleEvidence[],
  staleAfterMinutes: number,
  feeds: { automatic: boolean; manual: boolean },
): RuleSummary[] {
  const toolkitVerified = snapshot.toolkit.matches === true &&
    /^[a-f0-9]{40}$/i.test(snapshot.toolkit.actualHead) &&
    /^[a-f0-9]{40}$/i.test(snapshot.toolkit.actualTree);
  const blocked = snapshot.failures.some((failure) => !failure.id.startsWith("refused:") &&
    ["missing-data", "drift", "invalid-signature", "ambiguous-write", "recovery-needed",
      "task-failure", "stale-head"].includes(failure.category));
  const complete = !snapshot.truncated && !snapshot.quarantine.length &&
    !snapshot.diagnostics.length && !blocked;
  const now = Date.parse(snapshot.generatedAtUtc);
  const definitions = IMPLEMENTED_RULES.flatMap((definition) => {
    if (definition.runChannel !== "relation") return [definition];
    const identities = [...new Set(evidence.filter((item) =>
      item.capabilityId === definition.capabilityId).map((item) => item.ruleId))].sort();
    return identities.length ? identities.map((id) => ({ ...definition, id })) : [definition];
  });
  return definitions.map((definition) => {
    const gaps: string[] = [];
    if (!toolkitVerified) gaps.push("Installed toolkit head/tree is not verified against the configured pin.");
    if (!complete) gaps.push("Local feeds are missing, malformed, quarantined, or truncated; counts are unknown.");
    const runs = snapshot.runs.filter((run) =>
      run.toolkitHead === snapshot.toolkit.actualHead &&
      run.toolkitTree === snapshot.toolkit.actualTree &&
      runIdentities(run, definition.runChannel).length > 0 &&
      run.health === "healthy" &&
      (definition.runChannel === "relation" ? run.relationFailed === 0 : run.ownerFailed === 0),
    );
    const ownerRuleIds = new Set(evidence.filter((item) =>
      item.capabilityId === definition.capabilityId).map((item) => item.ruleId));
    const ambiguousOwner = definition.runChannel === "owner" && ownerRuleIds.size > 1;
    if (ambiguousOwner) gaps.push("Multiple Owner source rule identities share one capability; mapping is ambiguous.");
    const matched = new Map<string, { state: RuleEvidence; run: RunSummary }>();
    if (toolkitVerified && complete && !ambiguousOwner) {
      for (const run of runs) {
        for (const identity of runIdentities(run, definition.runChannel)) {
          const states = evidence.filter((candidate) =>
            candidate.identity === identity && candidate.capabilityId === definition.capabilityId &&
            candidate.ruleId.length > 0 &&
            (definition.runChannel === "owner" ||
              candidate.ruleId === definition.id));
          if (states.length !== 1) continue;
          const state = states[0]!;
          if (Date.parse(state.evaluatedUtc) > Date.parse(run.occurredUtc)) continue;
          const previous = matched.get(identity);
          if (!previous || Date.parse(previous.run.occurredUtc) < Date.parse(run.occurredUtc)) {
            matched.set(identity, { state, run });
          }
        }
      }
    }
    const bound = [...matched.values()];
    const latest = [...bound].sort((a, b) => Date.parse(b.run.occurredUtc) - Date.parse(a.run.occurredUtc))[0];
    if (!latest) gaps.push("No completed observation is bound to a matching pinned run generation.");
    const evaluatedUtc = latest?.state.evaluatedUtc ?? null;
    const fresh = latest !== undefined && evaluatedUtc !== null && Number.isFinite(now) &&
      now >= Date.parse(latest.run.occurredUtc) &&
      now >= Date.parse(evaluatedUtc) &&
      now - Date.parse(evaluatedUtc) <= staleAfterMinutes * 60_000;
    if (latest && !fresh) gaps.push("Last bound evaluation is stale or has an invalid/future timestamp.");
    const scoped = bound.map((item) => item.state);
    const findingIds = [...new Set(scoped.flatMap((state) => state.findingIds))];
    const linkedFindings = snapshot.findings.filter((finding: FindingSummary) =>
      finding.capability === definition.capabilityId &&
      scoped.some((state) => state.pullRequestId === finding.pullRequestId &&
        state.findingIds.includes(finding.id)));
    const linkedRelations = snapshot.relations.filter((finding) =>
      finding.capability === definition.capabilityId &&
      scoped.some((state) => state.pullRequestId === finding.pullRequestId &&
        state.findingIds.includes(finding.id)));
    const linkedDeliveries = snapshot.deliveries.filter((delivery) =>
      matchingDelivery(delivery, definition, scoped));
    const deliveryEvidenceComplete = complete && (feeds.automatic || feeds.manual);
    if (!deliveryEvidenceComplete) gaps.push("Verified delivery feed unavailable; posting and refusal counts are unknown.");
    gaps.push("Skipped/PR-intake denominator is not emitted per rule; skipped count and total coverage are unknown.");
    const sum = (field: "findings" | "noOp" | "wouldCreate" | "unknown") =>
      scoped.reduce((total, state) => total + state[field], 0);
    const counts: RuleOutcomeCounts = {
      finding: latest ? sum("findings") : null,
      noOp: latest ? sum("noOp") : null,
      wouldCreate: latest ? sum("wouldCreate") : null,
      unknown: latest ? sum("unknown") : null,
      skipped: null,
      refused: latest && deliveryEvidenceComplete
        ? linkedDeliveries.filter((item) => item.outcome === "refused").length : null,
      posted: latest && deliveryEvidenceComplete
        ? linkedDeliveries.filter((item) => item.providerWrites > 0 &&
          item.providerWriteState === "confirmed" &&
          /^(created|updated|created-confirmed-after-error|recovered-confirmed)$/.test(item.outcome)).length : null,
    };
    const classRule = definition.runChannel === "coverage";
    const classPinnedOut = classRule && !latest && toolkitVerified && complete;
    const deployment: RuleStatus = classPinnedOut ? "not-deployed" :
      latest && toolkitVerified ? "verified" : "unknown";
    const enablement: RuleStatus = classPinnedOut ? "disabled" :
      !snapshot.task.available ? "unknown" :
        snapshot.task.enabled === false ? "disabled" :
          snapshot.task.enabled === true && deployment === "verified" ? "verified" : "unknown";
    const authorization: PublishingStatus = definition.runChannel === "relation" ? "not-eligible" :
      classPinnedOut ? "disabled" :
        !toolkitVerified || !feeds.automatic ? "unknown" :
          definition.runChannel === "owner" && snapshot.toolkit.automaticEnabled === true &&
            snapshot.toolkit.policyId && snapshot.toolkit.maxCreatesPerRun !== null &&
            snapshot.toolkit.maxCreatesPerRun > 0 &&
            snapshot.toolkit.maxCreatesPerPullRequest !== null &&
            snapshot.toolkit.maxCreatesPerPullRequest > 0 ? "enabled" :
            definition.runChannel === "owner" && snapshot.toolkit.automaticEnabled === false ? "disabled" :
              "unknown";
    const publishing: PublishingStatus = authorization === "not-eligible" ? "not-eligible" :
      authorization === "disabled" || enablement === "disabled" ? "disabled" :
        authorization === "enabled" && enablement === "verified" ? "enabled" : "unknown";
    if (classPinnedOut) gaps.push("Operator reports class coverage not deployed; local data has no bound class run. Do not infer deployment from PR 174 code.");
    if (definition.runChannel === "coverage" && !classPinnedOut && publishing === "unknown") {
      gaps.push("No verified class-specific automatic authorization; code or Owner policy is not enablement.");
    }
    return {
      id: definition.id,
      sourceRuleId: latest?.state.ruleId ?? null,
      description: definition.description,
      provenance: definition.provenance,
      implementationVersion: definition.implementationVersion,
      installedHead: toolkitVerified ? snapshot.toolkit.actualHead : null,
      pinnedHead: toolkitVerified ? snapshot.toolkit.expectedHead : null,
      capabilityId: definition.capabilityId,
      implemented: true,
      deployment,
      enablement,
      execution: latest ? fresh ? "verified" : "stale" : "unknown",
      authorization,
      publishing,
      policyCaps: definition.runChannel === "owner" && authorization === "enabled" &&
        snapshot.toolkit.maxCreatesPerRun !== null &&
        snapshot.toolkit.maxCreatesPerPullRequest !== null
        ? { perRun: snapshot.toolkit.maxCreatesPerRun,
          perPullRequest: snapshot.toolkit.maxCreatesPerPullRequest }
        : null,
      scope: [...new Set(scoped.map((item) => item.pullRequestId))].sort((a, b) => a - b),
      lastGeneration: latest?.run.runId ?? null,
      lastEvaluatedUtc: evaluatedUtc,
      counts,
      findingIds,
      deliveryIds: linkedDeliveries.map((item) => item.id),
      url: linkedDeliveries.find((item) => item.commentUrl)?.commentUrl ??
        linkedFindings.find((item) => item.url)?.url ??
        linkedRelations.find((item) => item.url)?.url ?? null,
      gaps,
    };
  });
}
