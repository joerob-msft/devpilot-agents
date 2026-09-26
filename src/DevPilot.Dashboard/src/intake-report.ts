export type IntakeState = "complete" | "unknown";
export type IntakeHeadState = "pending" | "skipped" | "unknown" | "error";

export interface IntakeHead {
  pullRequestId: number;
  sourceCommit: string | null;
  targetCommit: string | null;
  targetRef: string | null;
  iterationId: number | null;
  state: IntakeHeadState;
  reason: string;
  rules: Array<{ capabilityId: string; ruleId: string; state: IntakeHeadState; reason: string }>;
}

export interface IntakeRule {
  capabilityId: string;
  ruleId: string;
  discovered: number | null;
  eligible: number | null;
  evaluated: number;
  skipped: number;
  error: number;
  unknown: number;
  pending: number;
  gaps: string[];
}

export interface IntakeSummary {
  binding: {
    organization: string;
    projectId: string;
    repositoryId: string;
  } | null;
  generation: string;
  observedUtc: string;
  state: IntakeState;
  discovered: number | null;
  eligible: number | null;
  excludedOtherTargets: number | null;
  heads: IntakeHead[];
  rules: IntakeRule[];
  gaps: string[];
}

const object = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("intake cohort contains an invalid object");
  }
  return value as Record<string, unknown>;
};

const count = (value: unknown): number => {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error("intake cohort has an invalid count");
  }
  return value as number;
};

const identifier = (value: unknown): string => {
  if (typeof value !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,127}$/.test(value)) {
    throw new Error("intake cohort has an invalid rule identity");
  }
  return value;
};

const reason = (value: unknown): string => {
  if (typeof value !== "string" || !/^[a-z][a-z0-9-]{0,79}$/.test(value)) {
    throw new Error("intake cohort has an invalid reason code");
  }
  return value;
};

export function parseIntakeCohort(value: unknown): IntakeSummary {
  const raw = object(value);
  if (raw.schemaVersion !== 1 || raw.kind !== "active-pr-intake-cohort") {
    throw new Error("unsupported intake cohort kind or version");
  }
  const binding = object(raw.binding);
  const organization = binding.organization;
  const projectId = binding.projectId;
  const repositoryId = binding.repositoryId;
  if (typeof organization !== "string" ||
      !/^https:\/\/dev\.azure\.com\/[a-zA-Z0-9_-]+\/?$/.test(organization) ||
      typeof projectId !== "string" || !/^[a-fA-F0-9-]{36}$/.test(projectId) ||
      typeof repositoryId !== "string" || !/^[a-fA-F0-9-]{36}$/.test(repositoryId)) {
    throw new Error("intake cohort has an invalid repository binding");
  }
  const generation = raw.generation;
  if (typeof generation !== "string" || !/^[a-zA-Z0-9:._-]{1,128}$/.test(generation)) {
    throw new Error("intake generation is invalid");
  }
  if (!/^[a-f0-9]{32}$/.test(generation) ||
      raw.generationFile !== `generations${process.platform === "win32" ? "\\" : "/"}${generation}.json`) {
    throw new Error("intake immutable generation reference is invalid");
  }
  const observedUtc = raw.observedUtc;
  if (typeof observedUtc !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/.test(observedUtc) ||
      !Number.isFinite(Date.parse(observedUtc))) {
    throw new Error("intake timestamp is invalid");
  }
  const inventory = object(raw.inventory);
  if (inventory.state !== "complete" && inventory.state !== "unknown") {
    throw new Error("intake inventory state is invalid");
  }
  const discovered = inventory.discovered === null ? null : count(inventory.discovered);
  const eligible = inventory.eligible === null ? null : count(inventory.eligible);
  const excludedOtherTargets = inventory.excludedOtherTargets === null
    ? null : count(inventory.excludedOtherTargets);
  if (!Array.isArray(raw.heads) || raw.heads.length > 2_000 ||
      !Array.isArray(raw.rules) || raw.rules.length > 32) {
    throw new Error("intake cohort exceeds its head or rule budget");
  }
  const seenHeads = new Set<number>();
  const heads: IntakeHead[] = raw.heads.map((item: unknown) => {
    const head = object(item);
    const pullRequestId = count(head.pullRequestId);
    if (!pullRequestId || seenHeads.has(pullRequestId)) {
      throw new Error("intake cohort has a duplicate or invalid PR identity");
    }
    seenHeads.add(pullRequestId);
    const sourceCommit = head.sourceCommit;
    const targetCommit = head.targetCommit;
    const targetRef = head.targetRef;
    const iterationId = head.iterationId === null ? null : count(head.iterationId);
    const state = head.status;
    if ((sourceCommit !== null && (typeof sourceCommit !== "string" || !/^[a-f0-9]{40}$/.test(sourceCommit))) ||
        (targetCommit !== null && (typeof targetCommit !== "string" || !/^[a-f0-9]{40}$/.test(targetCommit))) ||
        (targetRef !== null && (typeof targetRef !== "string" ||
          !/^refs\/heads\/[a-zA-Z0-9._/-]{1,200}$/.test(targetRef))) ||
        !["pending", "skipped", "unknown", "error"].includes(String(state))) {
      throw new Error("intake cohort has an invalid immutable head");
    }
    if (!Array.isArray(head.rules) || head.rules.length > 32) {
      throw new Error("intake head rule inventory is invalid");
    }
    const seenHeadRules = new Set<string>();
    const rules = head.rules.map((item: unknown) => {
      const rule = object(item);
      const capabilityId = identifier(rule.capabilityId);
      const ruleId = identifier(rule.ruleId);
      const key = `${capabilityId}\0${ruleId}`;
      if (seenHeadRules.has(key) ||
          !["pending", "skipped", "unknown", "error"].includes(String(rule.status))) {
        throw new Error("intake head has a duplicate or unverified rule outcome");
      }
      seenHeadRules.add(key);
      return { capabilityId, ruleId, state: rule.status as IntakeHeadState,
        reason: reason(rule.reasonCode) };
    });
    return {
      pullRequestId, sourceCommit: sourceCommit as string | null,
      targetCommit: targetCommit as string | null,
      targetRef: targetRef as string | null, iterationId,
      state: state as IntakeHeadState, reason: reason(head.reason), rules,
    };
  });
  if (inventory.state === "complete" &&
      (discovered !== heads.length || eligible === null || excludedOtherTargets === null ||
        eligible + excludedOtherTargets !== discovered ||
        heads.some((head) => head.targetRef === null) ||
        heads.some((head) => head.targetRef !== "refs/heads/master" &&
          (head.state !== "skipped" || head.reason !== "target-out-of-policy")) ||
        heads.filter((head) => head.targetRef !== "refs/heads/master").length !== excludedOtherTargets)) {
    throw new Error("intake denominator does not match the immutable head inventory");
  }
  const seenRules = new Set<string>();
  const rules: IntakeRule[] = raw.rules.map((item: unknown) => {
    const rule = object(item);
    const capabilityId = identifier(rule.capabilityId);
    const ruleId = identifier(rule.ruleId);
    const key = `${capabilityId}\0${ruleId}`;
    if (seenRules.has(key)) throw new Error("intake cohort has duplicate rule identity");
    seenRules.add(key);
    const counts = {
      discovered: rule.discovered === null ? null : count(rule.discovered),
      eligible: rule.eligible === null ? null : count(rule.eligible),
      evaluated: count(rule.evaluated), skipped: count(rule.skipped),
      error: count(rule.error), unknown: count(rule.unknown ?? 0),
      pending: count(rule.pending),
    };
    if (counts.evaluated !== 0 ||
        (counts.eligible !== null && counts.eligible > heads.length) ||
        (counts.discovered !== null &&
          counts.evaluated + counts.skipped + counts.error + counts.unknown + counts.pending > counts.discovered) ||
        (inventory.state === "complete" &&
          (counts.discovered === null || counts.eligible === null ||
            counts.evaluated + counts.skipped + counts.error + counts.unknown + counts.pending !== counts.discovered ||
            counts.discovered !== discovered || counts.eligible !== eligible))) {
      throw new Error("intake cannot claim evaluation without a completed current-head observation");
    }
    if (inventory.state === "complete") {
      const statuses = heads.map((head) => {
        const found = head.rules.filter((candidate) =>
          candidate.capabilityId === capabilityId && candidate.ruleId === ruleId);
        if (found.length !== 1) throw new Error("intake per-head rule denominator is incomplete");
        return found[0]!.state;
      });
      if (statuses.filter((status) => status === "skipped").length !== counts.skipped ||
          statuses.filter((status) => status === "pending").length !== counts.pending ||
          statuses.filter((status) => status === "unknown" || status === "error").length !== counts.error) {
        throw new Error("intake rule counts do not reconcile with per-head outcomes");
      }
    }
    if (!Array.isArray(rule.gaps) || rule.gaps.length > 20) {
      throw new Error("intake rule gaps exceed the budget");
    }
    return {
      capabilityId, ruleId, ...counts,
      gaps: rule.gaps.map(reason),
    };
  });
  const gaps = raw.gaps;
  if (!Array.isArray(gaps) || gaps.length > 20) throw new Error("intake gaps exceed the budget");
  return {
    binding: { organization: organization.replace(/\/$/, ""),
      projectId: projectId.toLowerCase(), repositoryId: repositoryId.toLowerCase() },
    generation, observedUtc, state: inventory.state,
    discovered, eligible, excludedOtherTargets, heads, rules, gaps: gaps.map(reason),
  };
}
