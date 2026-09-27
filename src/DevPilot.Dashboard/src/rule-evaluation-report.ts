import { createHash } from "node:crypto";
import type { IntakeSummary } from "./intake-report.js";

export type EvaluationStatus = "evaluated" | "pending" | "skipped" | "unknown" | "error";
export interface EvaluationHead {
  pullRequestId: number;
  url?: string;
  sourceCommit: string | null;
  targetCommit: string | null;
  targetRef: string | null;
  iterationId: number | null;
  rules: Array<{
    capabilityId: string;
    ruleId: string;
    status: EvaluationStatus;
    reasonCode: string;
    observationDigest: string | null;
    declarationDigest: string | null;
    outcome?: { findings: number; noOp: number; humanCovered: number; wouldCreate: number; unknown: number };
  }>;
}
export interface EvaluationRule {
  capabilityId: string;
  ruleId: string;
  discovered: number;
  eligible: number;
  evaluated: number;
  skipped: number;
  unknown: number;
  error: number;
  pending: number;
  gaps: string[];
}
export interface RuleEvaluationSummary {
  state: "complete" | "unknown";
  generation: string;
  intakeGeneration: string;
  observedUtc: string;
  binding: { organization: string; projectId: string; repositoryId: string; configDigest: string } | null;
  discovered: number | null;
  eligible: number | null;
  excludedOtherTargets: number | null;
  draftExcluded: number | null;
  heads: EvaluationHead[];
  rules: EvaluationRule[];
  gaps: string[];
}

const record = (value: unknown): Record<string, unknown> => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid rule evaluation object");
  }
  return value as Record<string, unknown>;
};
const nonnegative = (value: unknown): number => {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error("invalid rule evaluation count");
  return value as number;
};
const identity = (value: unknown): string => {
  if (typeof value !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,127}$/.test(value)) {
    throw new Error("invalid rule evaluation identity");
  }
  return value;
};
const code = (value: unknown): string => {
  if (typeof value !== "string" || !/^[a-z][a-z0-9-]{0,79}$/.test(value)) {
    throw new Error("invalid rule evaluation reason");
  }
  return value;
};
const hex = (value: unknown, length: number): string => {
  if (typeof value !== "string" || !new RegExp(`^[a-f0-9]{${length}}$`).test(value)) {
    throw new Error("invalid rule evaluation digest or generation");
  }
  return value;
};
const utc = (value: unknown): string => {
  if (typeof value !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/.test(value) ||
      !Number.isFinite(Date.parse(value))) throw new Error("invalid rule evaluation timestamp");
  return value;
};
const listCodes = (value: unknown): string[] => {
  if (!Array.isArray(value) || value.length > 20) throw new Error("rule evaluation gaps exceed budget");
  return value.map(code);
};
const ruleKey = (capabilityId: string, ruleId: string) => `${capabilityId}\0${ruleId}`;
const jsonBytes = (bytes: Buffer): Record<string, unknown> =>
  record(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as unknown);

export function unknownRuleEvaluation(gap: string): RuleEvaluationSummary {
  return {
    state: "unknown", generation: "", intakeGeneration: "", observedUtc: "",
    binding: null, discovered: null, eligible: null, excludedOtherTargets: null,
    draftExcluded: null,
    heads: [], rules: [], gaps: [gap],
  };
}

export function parseRuleEvaluationCohort(value: unknown, intake: IntakeSummary): RuleEvaluationSummary {
  const raw = record(value);
  if (raw.schemaVersion !== 1 || raw.kind !== "scheduled-rule-evaluation-cohort") {
    throw new Error("unsupported rule evaluation cohort");
  }
  if (intake.state !== "complete" || !intake.binding) throw new Error("unverified intake generation");
  const generation = hex(raw.generation, 32);
  const intakeGeneration = hex(raw.intakeGeneration, 32);
  if (intakeGeneration !== intake.generation) throw new Error("rule evaluation intake generation mismatch");
  const binding = record(raw.binding);
  const organization = binding.organization;
  const projectId = binding.projectId;
  const repositoryId = binding.repositoryId;
  if (typeof organization !== "string" || typeof projectId !== "string" || typeof repositoryId !== "string" ||
      organization.replace(/\/$/, "").toLowerCase() !== intake.binding.organization.toLowerCase() ||
      projectId.toLowerCase() !== intake.binding.projectId.toLowerCase() ||
      repositoryId.toLowerCase() !== intake.binding.repositoryId.toLowerCase()) {
    throw new Error("rule evaluation repository binding mismatch");
  }
  const configDigest = hex(binding.configDigest, 64);
  const observedUtc = utc(raw.observedUtc);
  const inventory = record(raw.inventory);
  const discovered = nonnegative(inventory.discovered);
  const eligible = nonnegative(inventory.eligible);
  const excludedOtherTargets = nonnegative(inventory.excludedOtherTargets);
  const draftExcluded = inventory.draftExcluded === undefined
    ? null : nonnegative(inventory.draftExcluded);
  if (inventory.state !== "complete" || discovered !== intake.discovered ||
      eligible !== intake.eligible || excludedOtherTargets !== intake.excludedOtherTargets ||
      (draftExcluded !== null && draftExcluded > 10_000) ||
      eligible + excludedOtherTargets !== discovered ||
      !Array.isArray(raw.heads) || raw.heads.length !== discovered || raw.heads.length > 2_000 ||
      !Array.isArray(raw.rules) || raw.rules.length > 32) {
    throw new Error("rule evaluation inventory does not match intake");
  }
  const intakeHeads = new Map(intake.heads.map((head) => [head.pullRequestId, head]));
  const seenHeads = new Set<number>();
  const heads: EvaluationHead[] = raw.heads.map((item: unknown) => {
    const head = record(item);
    const pullRequestId = nonnegative(head.pullRequestId);
    const source = intakeHeads.get(pullRequestId);
    if (!pullRequestId || seenHeads.has(pullRequestId) || !source ||
        head.sourceCommit !== source.sourceCommit || head.targetCommit !== source.targetCommit ||
        head.targetRef !== source.targetRef || head.iterationId !== source.iterationId ||
        !Array.isArray(head.rules) || head.rules.length > 32) {
      throw new Error("rule evaluation head does not match intake");
    }
    seenHeads.add(pullRequestId);
    const seen = new Set<string>();
    const rules = head.rules.map((entry: unknown) => {
      const candidate = record(entry);
      const capabilityId = identity(candidate.capabilityId);
      const ruleId = identity(candidate.ruleId);
      const key = ruleKey(capabilityId, ruleId);
      const status = candidate.status;
      if (seen.has(key) || !["evaluated", "pending", "skipped", "unknown", "error"].includes(String(status))) {
        throw new Error("invalid per-head rule evaluation");
      }
      seen.add(key);
      const digest = candidate.observationDigest;
      const declarationDigest = candidate.declarationDigest;
      if (digest !== null && digest !== undefined) hex(digest, 64);
      if (declarationDigest !== null && declarationDigest !== undefined) hex(declarationDigest, 64);
      if ((status === "evaluated") !== (typeof digest === "string") ||
          (status === "evaluated" && typeof declarationDigest !== "string") ||
          (status === "evaluated" && (sourceCommitMissing(source) || source.targetRef !== "refs/heads/master"))) {
        throw new Error("rule evaluation without current-head evidence");
      }
      return {
        capabilityId, ruleId, status: status as EvaluationStatus,
        reasonCode: code(candidate.reasonCode),
        observationDigest: typeof digest === "string" ? digest : null,
        declarationDigest: typeof declarationDigest === "string" ? declarationDigest : null,
      };
    });
    return {
      pullRequestId, sourceCommit: source.sourceCommit, targetCommit: source.targetCommit,
      targetRef: source.targetRef, iterationId: source.iterationId, rules,
    };
  });
  const seenRules = new Set<string>();
  const rules: EvaluationRule[] = raw.rules.map((item: unknown) => {
    const candidate = record(item);
    const capabilityId = identity(candidate.capabilityId);
    const ruleId = identity(candidate.ruleId);
    const key = ruleKey(capabilityId, ruleId);
    if (seenRules.has(key)) throw new Error("duplicate rule evaluation identity");
    seenRules.add(key);
    const counts = {
      discovered: nonnegative(candidate.discovered), eligible: nonnegative(candidate.eligible),
      evaluated: nonnegative(candidate.evaluated), skipped: nonnegative(candidate.skipped),
      unknown: nonnegative(candidate.unknown), error: nonnegative(candidate.error),
      pending: nonnegative(candidate.pending),
    };
    if (counts.discovered !== discovered || counts.eligible !== eligible ||
        counts.evaluated + counts.skipped + counts.unknown + counts.error + counts.pending !== discovered) {
      throw new Error("rule evaluation totals do not reconcile");
    }
    for (const head of heads) {
      if (head.rules.filter((entry) => ruleKey(entry.capabilityId, entry.ruleId) === key).length !== 1) {
        throw new Error("missing per-head rule evaluation");
      }
    }
    for (const status of ["evaluated", "skipped", "unknown", "error", "pending"] as const) {
      if (heads.reduce((total, head) => total + Number(head.rules.some((entry) =>
        ruleKey(entry.capabilityId, entry.ruleId) === key && entry.status === status)), 0) !== counts[status]) {
        throw new Error("per-head rule evaluation totals do not reconcile");
      }
    }
    return { capabilityId, ruleId, ...counts, gaps: listCodes(candidate.gaps) };
  });
  if (heads.some((head) => head.rules.length !== rules.length)) {
    throw new Error("undeclared per-head rule evaluation");
  }
  return {
    state: "complete", generation, intakeGeneration, observedUtc,
    binding: { organization: organization.replace(/\/$/, ""), projectId, repositoryId, configDigest },
    discovered, eligible, excludedOtherTargets, draftExcluded, heads, rules, gaps: listCodes(raw.gaps),
  };
}

function sourceCommitMissing(head: IntakeSummary["heads"][number]): boolean {
  return !head.sourceCommit || !head.targetCommit || !head.targetRef || head.iterationId === null;
}

export function verifyRuleObservation(
  bytes: Buffer, digest: string, summary: RuleEvaluationSummary,
  head: EvaluationHead, rule: EvaluationHead["rules"][number], maxFindingsPerHead: number,
  projectEvidenceDigest?: string | null,
): boolean {
  try {
    if (createHash("sha256").update(bytes).digest("hex") !== digest) return false;
    const observation = jsonBytes(bytes);
    const outcome = record(observation.outcome);
    if (rule.capabilityId === "bpm-test-ownership@1") {
      const proof = record(observation.ownerProof);
      if (proof.completed !== true || proof.providerWrites !== 0 ||
          proof.writeToolInvocations !== 0 || proof.modelToolInvocations !== 0 ||
          nonnegative(proof.manifestEntryCount) !== 1 ||
          typeof proof.identity !== "string" ||
          !/^[a-f0-9]{64}$/.test(proof.identity) ||
          proof.stateDigest !== `v1:sha256:${proof.identity}` ||
          ["manifestDigest", "observationDigest", "recordFileDigest",
            "manifestFileDigest", "acquisitionPayloadDigest"].some((key) =>
            typeof proof[key] !== "string" ||
            !/^v1:sha256:[a-f0-9]{64}$/.test(proof[key]))) return false;
    }
    const findingOutcomes = observation.findingOutcomes;
    const completed = utc(observation.completedUtc);
    if (rule.capabilityId === "bpm-test-class-coverage@2" ||
        rule.capabilityId === "bpm-redundant-method-coverage@2") {
      if (!projectEvidenceDigest || observation.projectEvidenceDigest !== projectEvidenceDigest) {
        return false;
      }
    }
    if (observation.schemaVersion !== 1 || observation.kind !== "scheduled-rule-observation" ||
        observation.generation !== summary.generation ||
        observation.intakeGeneration !== summary.intakeGeneration ||
        observation.pullRequestId !== head.pullRequestId ||
        observation.sourceCommit !== head.sourceCommit ||
        observation.targetCommit !== head.targetCommit ||
        observation.targetRef !== head.targetRef ||
        observation.iterationId !== head.iterationId ||
        observation.capabilityId !== rule.capabilityId || observation.ruleId !== rule.ruleId ||
        observation.declarationDigest !== rule.declarationDigest ||
        Date.parse(completed) > Date.parse(summary.observedUtc) ||
        nonnegative(outcome.findings) > maxFindingsPerHead || nonnegative(outcome.noOp) > 100_000 ||
        nonnegative(outcome.humanCovered) > maxFindingsPerHead ||
        nonnegative(outcome.wouldCreate) > maxFindingsPerHead ||
        nonnegative(outcome.unknown) > maxFindingsPerHead ||
        (outcome.noOp as number) + (outcome.humanCovered as number) +
          (outcome.wouldCreate as number) + (outcome.unknown as number) !== outcome.findings ||
        typeof observation.discussionDigest !== "string" ||
        !/^[a-f0-9]{64}$/.test(observation.discussionDigest) ||
        !Array.isArray(findingOutcomes) ||
        findingOutcomes.length !== outcome.findings ||
        new Set(findingOutcomes.map((item: unknown) => record(item).findingDigest)).size !==
          findingOutcomes.length ||
        findingOutcomes.some((item: unknown) => {
          const finding = record(item);
          return typeof finding.findingDigest !== "string" ||
            !/^[a-f0-9]{64}$/.test(finding.findingDigest) ||
            !["noOp", "humanCovered", "wouldCreate", "unknown"].includes(String(finding.classification)) ||
            code(finding.reason).length === 0;
        }) ||
        ["noOp", "humanCovered", "wouldCreate", "unknown"].some((state) =>
          findingOutcomes.filter((item: unknown) =>
            record(item).classification === state).length !== outcome[state]) ||
        observation.providerWrites !== 0 || observation.modelToolInvocations !== 0) return false;
    return true;
  } catch {
    return false;
  }
}

export function verifyRuleDeclaration(
  bytes: Buffer, digest: string, summary: RuleEvaluationSummary,
  head: EvaluationHead, rule: EvaluationHead["rules"][number],
  intakeHead: IntakeSummary["heads"][number] | undefined,
  intakeDeclarationDigest: string | undefined,
): number | null {
  try {
    if (createHash("sha256").update(bytes).digest("hex") !== digest) return null;
    const declaration = jsonBytes(bytes);
    const max = nonnegative(declaration.maxFindingsPerHead);
    const policy = ({
      "bpm-test-class-coverage@1": "test-class-coverage",
      "bpm-redundant-method-coverage@1": "redundant-method-coverage",
      "bpm-named-areequal-arguments@1": "named-areequal-arguments",
    } as Record<string, string>)[rule.capabilityId];
    if (rule.capabilityId === "bpm-test-ownership@1") {
      const binding = record(declaration.ruleBinding);
      const model = record(declaration.model);
      if (typeof binding.ruleRepositoryId !== "string" ||
          !/^[A-Za-z0-9._/-]{1,256}$/.test(binding.ruleRepositoryId) ||
          binding.rulePath !== "documentation/EngineeringProcesses/Conventions/AutomatedTests.md" ||
          binding.ruleSection !== "## Claim ownership" ||
          binding.ruleCommit !== "f6db83436b48f48a8521095a888d79f67823bbb2" ||
          binding.ruleHash !== "v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f" ||
          nonnegative(binding.ruleLength) < 1 || (binding.ruleLength as number) > 65_536 ||
          typeof binding.capabilityDigest !== "string" ||
          !/^v1:sha256:[a-f0-9]{64}$/.test(binding.capabilityDigest) ||
          typeof model.id !== "string" || !/^[a-zA-Z0-9_.-]{1,128}$/.test(model.id) ||
          model.digest !== `v1:sha256:${createHash("sha256").update(model.id).digest("hex")}`) return null;
    }
    if (policy) {
      const binding = record(declaration.ruleBinding);
      if (typeof binding.ruleRepositoryId !== "string" ||
          !/^[A-Za-z0-9._/-]{1,256}$/.test(binding.ruleRepositoryId) ||
          binding.rulePath !== `src/DevPilot.OwnerCapability/Policy/${policy}.v1.txt` ||
          typeof binding.ruleCommit !== "string" ||
          !/^[a-f0-9]{40}$/.test(binding.ruleCommit) ||
          typeof binding.ruleHash !== "string" ||
          !/^v1:sha256:[a-f0-9]{64}$/.test(binding.ruleHash) ||
          typeof binding.capabilityDigest !== "string" ||
          !/^v1:sha256:[a-f0-9]{64}$/.test(binding.capabilityDigest)) return null;
    }
    if (!intakeHead?.lineEvidence || !intakeDeclarationDigest ||
        hex(intakeDeclarationDigest, 64) !== declaration.intakeDeclarationDigest ||
        declaration.lineEvidenceDigest !== intakeHead.lineEvidence.digest ||
        declaration.schemaVersion !== 1 || declaration.kind !== "scheduled-rule-declaration" ||
        declaration.generation !== summary.generation ||
        declaration.intakeGeneration !== summary.intakeGeneration ||
        declaration.pullRequestId !== head.pullRequestId ||
        declaration.sourceCommit !== head.sourceCommit ||
        declaration.targetCommit !== head.targetCommit ||
        declaration.targetRef !== head.targetRef ||
        declaration.iterationId !== head.iterationId ||
        declaration.configDigest !== summary.binding?.configDigest ||
        declaration.capabilityId !== rule.capabilityId ||
        declaration.ruleId !== rule.ruleId ||
        declaration.writerEligible !== false || max < 1 || max > 32) return null;
    if (rule.capabilityId === "bpm-test-class-coverage@2" ||
        rule.capabilityId === "bpm-redundant-method-coverage@2") {
      if (!intakeHead.projectEvidence?.complete ||
          declaration.projectEvidenceDigest !== intakeHead.projectEvidence.digest) return null;
    }
    return max;
  } catch {
    return null;
  }
}

export async function validateRuleObservations(
  summary: RuleEvaluationSummary,
  readObservation: (digest: string) => Promise<Buffer>,
  readDeclaration: (digest: string) => Promise<Buffer>,
  intake: IntakeSummary, intakeDeclarationDigests: ReadonlyMap<number, string>,
): Promise<RuleEvaluationSummary> {
  const heads: EvaluationHead[] = [];
  const intakeHeads = new Map(intake.heads.map((head) => [head.pullRequestId, head]));
  for (const head of summary.heads) {
    const rules: EvaluationHead["rules"] = [];
    for (const rule of head.rules) {
      if (rule.status !== "evaluated" || !rule.observationDigest || !rule.declarationDigest) {
        rules.push(rule);
        continue;
      }
      try {
        const declarationBytes = await readDeclaration(rule.declarationDigest);
        const max = verifyRuleDeclaration(declarationBytes, rule.declarationDigest, summary,
          head, rule, intakeHeads.get(head.pullRequestId),
          intakeDeclarationDigests.get(head.pullRequestId));
        if (max !== null) {
          const observationBytes = await readObservation(rule.observationDigest);
          if (verifyRuleObservation(observationBytes, rule.observationDigest, summary, head, rule, max,
            intakeHeads.get(head.pullRequestId)?.projectEvidence?.digest)) {
            const outcome = record(jsonBytes(observationBytes).outcome);
            rules.push({ ...rule, outcome: {
              findings: outcome.findings as number, noOp: outcome.noOp as number,
              humanCovered: outcome.humanCovered as number,
              wouldCreate: outcome.wouldCreate as number, unknown: outcome.unknown as number,
            } });
            continue;
          }
        }
      } catch { /* Missing or inaccessible evidence is unknown, never evaluated. */ }
      rules.push({ ...rule, status: "unknown", reasonCode: "observation-unverified",
        observationDigest: null });
    }
    heads.push({ ...head, rules });
  }
  const rules = summary.rules.map((rule) => {
    const statuses = heads.flatMap((head) => head.rules.filter((entry) =>
      entry.capabilityId === rule.capabilityId && entry.ruleId === rule.ruleId));
    const downgraded = statuses.some((entry) => entry.reasonCode === "observation-unverified");
    return {
      ...rule,
      evaluated: statuses.filter((entry) => entry.status === "evaluated").length,
      unknown: statuses.filter((entry) => entry.status === "unknown").length,
      gaps: downgraded ? [...new Set([...rule.gaps, "observation-unverified"])] : rule.gaps,
    };
  });
  return { ...summary, heads, rules,
    gaps: rules.some((rule) => rule.gaps.includes("observation-unverified"))
      ? [...new Set([...summary.gaps, "observation-unverified"])] : summary.gaps };
}
