import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import {
  LocalReportingAdapter,
  buildAzureDevOpsLinks,
  parseReportingConfiguration,
  type ReportingAdapterOptions,
  type TaskHealth,
} from "../src/reporting.js";
import {
  REPORTING_SECTIONS,
  filterReportingRows,
  overviewLines,
  reportingRows,
  type ReportingFilters,
} from "../src/reporting-view.js";
import { projectRuleRegistry } from "../src/rule-registry.js";
import { parseIntakeCohort } from "../src/intake-report.js";
import { parseRuleEvaluationCohort } from "../src/rule-evaluation-report.js";

type JsonRecord = Record<string, unknown>;
const execFileAsync = promisify(execFile);

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function canonical(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") return String(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const record = value as JsonRecord;
  return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${canonical(record[key])}`).join(",")}}`;
}

function sha256Text(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function canonicalDigest(value: unknown): string {
  return `v1:sha256:${sha256Text(canonical(value))}`;
}

function signedEnvelope(payload: JsonRecord, key: Buffer): string {
  const manifestJson = canonical(payload);
  return `${canonical({
    schemaVersion: 1,
    kind: "owner-v2-comment-signed-envelope",
    signatureAlg: "HMACSHA256",
    manifestJson,
    signature: createHmac("sha256", key).update(manifestJson, "utf8").digest("hex"),
  })}\n`;
}

async function write(path: string, value: string | Buffer): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, value);
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await write(path, `${JSON.stringify(value)}\n`);
}

async function copyIntoWindowsTrustedRoot(
  source: string, target: string, repositoryRoot: string, trustBoundary = repositoryRoot,
): Promise<void> {
  const harness = join(repositoryRoot, "src", "DevPilot.AgentHarness", "DevPilot.AgentHarness.psd1");
  const script = [
    "$ErrorActionPreference='Stop'",
    "Import-Module -Name $env:DEVPILOT_TEST_HARNESS -Force",
    "$root=Resolve-AgentTrustedRoot -Path $env:DEVPILOT_TEST_TARGET -Kind durable-state -RepositoryRoot $env:DEVPILOT_TEST_REPO -Create",
    "Get-ChildItem -LiteralPath $env:DEVPILOT_TEST_SOURCE -Force | Copy-Item -Destination $root -Recurse -Force",
  ].join(";");
  await execFileAsync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", script], {
    env: {
      ...process.env,
      DEVPILOT_TEST_HARNESS: harness,
      DEVPILOT_TEST_SOURCE: source,
      DEVPILOT_TEST_TARGET: target,
      DEVPILOT_TEST_REPO: trustBoundary,
    },
    timeout: 30_000,
    maxBuffer: 64 * 1_024,
    windowsHide: true,
  });
}

const healthyTask: TaskHealth = {
  available: true,
  enabled: true,
  state: "Ready",
  lastRunUtc: "2026-09-24T20:00:00.000Z",
  nextRunUtc: "2026-09-24T21:00:00.000Z",
  lastResult: 0,
  diagnostic: "",
};

interface Fixture {
  root: string;
  configPath: string;
  stateRoot: string;
  toolkitRoot: string;
  deliveryRoot: string;
  manualRoot: string;
  runnerRoot: string;
  serviceKey: Buffer;
  manualKey: Buffer;
  identity: string;
  findingId: string;
  marker: string;
  body: string;
}

function createAdapter(path: string, options: ReportingAdapterOptions = {}): LocalReportingAdapter {
  return new LocalReportingAdapter(path, {
    ...options,
    keyPermissionChecker: options.keyPermissionChecker ?? (async () => true),
  });
}

async function createFixture(options: { maxHistory?: number } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(process.cwd(), ".reporting-test-"));
  const stateRoot = join(root, "state");
  const toolkitRoot = join(root, "toolkit");
  const deliveryRoot = join(root, "delivery");
  const manualRoot = join(root, "manual");
  const runnerRoot = join(root, "runner");
  for (const directory of [stateRoot, toolkitRoot, deliveryRoot, manualRoot, runnerRoot]) {
    await mkdir(directory, { recursive: true, mode: 0o700 });
  }
  const serviceKey = randomBytes(32);
  const manualKey = randomBytes(32);
  const serviceKeyPath = join(deliveryRoot, "keys", "owner-v2-service-authorization.hmac");
  const manualKeyPath = join(manualRoot, "keys", "owner-v2-comment-approval.hmac");
  await write(serviceKeyPath, serviceKey);
  await write(manualKeyPath, manualKey);
  await chmod(serviceKeyPath, 0o600);
  await chmod(manualKeyPath, 0o600);

  const identity = "a".repeat(64);
  const findingId = `owner-v2:${"b".repeat(64)}`;
  const marker = "c".repeat(64);
  const body = [
    "**Owner attribute missing**",
    "",
    "Method `<script>alert(1)</script>` at `tests/Widget Tests.cs:12` is missing Owner.",
  ].join("\n");
  const bodySha256 = sha256Text(body);
  const capabilityRoot = join(stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "owner");
  const ownerDeclaration = {
    kind: "owner-v2-preview-declaration",
    stateDigest: `v1:sha256:${identity}`,
    subject: {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
    },
    head: { sourceCommit: "d".repeat(40) },
    target: { targetCommit: "2".repeat(40), targetRef: "refs/heads/main" },
    capability: {
      id: "bpm-test-ownership@1",
      digest: `v1:sha256:${"3".repeat(64)}`,
    },
    rule: { section: "## Claim ownership", path: "rules/owner.md", commit: "d".repeat(40) },
  };
  await writeJson(join(capabilityRoot, "declarations", `${identity}.json`), ownerDeclaration);
  await writeJson(join(capabilityRoot, "records", `${identity}.json`), {
    identity,
    stateDigest: ownerDeclaration.stateDigest,
    state: "completed",
    capabilityId: ownerDeclaration.capability.id,
    capabilityDigest: ownerDeclaration.capability.digest,
    subjectDigest: canonicalDigest(ownerDeclaration.subject),
    headDigest: canonicalDigest(ownerDeclaration.head),
    updatedUtc: "utc:2026-09-24T20:00:00Z",
  });
  await writeJson(join(capabilityRoot, "observations", `${identity}.json`), {
    schemaVersion: 2,
    kind: "owner-observation",
    capability: "bpm-test-ownership@1",
    subject: {
      projectId: null,
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
      headCommit: "d".repeat(40),
      targetCommit: "2".repeat(40),
      targetRef: "refs/heads/main",
    },
    rule: { path: "rules/owner.md", section: "## Claim ownership", commit: "d".repeat(40) },
    lifecycle: { status: "completed" },
    findings: [{
      identity: findingId,
      disposition: "violation",
      anchor: { path: "tests/Widget Tests.cs", line: 12, symbol: "<script>alert(1)</script>" },
      reconciliation: {
        classification: "noOp",
        reason: "reviewer-marker-body-current",
        bodySha256,
        thread: {
          availability: "available",
          threadId: 200,
          commentId: 201,
          status: "active",
        },
      },
    }],
  });
  const relationIdentity = "e".repeat(64);
  const relationRoot = join(stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "relation");
  const relationDeclaration = {
    kind: "relation-v2-preview-declaration",
    stateDigest: `v1:sha256:${relationIdentity}`,
    subject: {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
    },
    head: { sourceCommit: "d".repeat(40) },
    target: { targetCommit: "2".repeat(40), targetRef: "refs/heads/main" },
    capability: {
      id: "relation-contextual-review-v1",
      digest: `v1:sha256:${"4".repeat(64)}`,
    },
    rule: { id: "synthetic-relation-rule-v1", hash: `v1:sha256:${"5".repeat(64)}` },
  };
  await writeJson(join(relationRoot, "declarations", `${relationIdentity}.json`), relationDeclaration);
  await writeJson(join(relationRoot, "records", `${relationIdentity}.json`), {
    identity: relationIdentity,
    stateDigest: relationDeclaration.stateDigest,
    state: "completed",
    capabilityId: relationDeclaration.capability.id,
    capabilityDigest: relationDeclaration.capability.digest,
    subjectDigest: canonicalDigest(relationDeclaration.subject),
    headDigest: canonicalDigest(relationDeclaration.head),
    updatedUtc: "utc:2026-09-24T19:00:00Z",
  });
  await writeJson(join(relationRoot, "observations", `${relationIdentity}.json`), {
    schemaVersion: 1,
    kind: "relation-evidence-observation",
    capability: { id: "relation-contextual-review-v1" },
    subject: {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
      sourceCommit: "d".repeat(40),
      targetCommit: "2".repeat(40),
      targetRef: "refs/heads/main",
    },
    rule: { id: "synthetic-relation-rule-v1", digest: `v1:sha256:${"5".repeat(64)}` },
    lifecycle: { status: "completed" },
    findings: [{
      findingId: "relation:1",
      data: {
        capabilityId: "relation-contextual-review-v1",
        ruleId: "synthetic-relation-rule-v1",
        disposition: "violation",
        explanation: "Synthetic relation assessment is bound to the historical snapshot.",
        anchor: { path: "src/Widget.cs", startLine: 8, symbol: "Widget" },
      },
      writerEligible: false,
    }],
  });

  const formatterPath = join(toolkitRoot, "src", "DevPilot.OwnerCapability", "DevPilot.OwnerCapability.psm1");
  await write(formatterPath, "formatter fixture\n");
  const formatterSha256 = createHash("sha256").update("formatter fixture\n").digest("hex");
  const policyPath = join(deliveryRoot, "policies", "owner-v2-production.json");
  const policyEnvelope = signedEnvelope({
    schemaVersion: 1,
    kind: "owner-v2-service-authorization-policy",
    policyId: "owner-v2-production",
    limits: { maxCreatesPerRun: 5, maxCreatesPerPullRequest: 25 },
  }, serviceKey);
  await write(policyPath, policyEnvelope);
  const toolkitConfigPath = join(toolkitRoot, "owner-v2-config.json");
  await writeJson(toolkitConfigPath, {
    toolkit: { head: "f".repeat(40), tree: "1".repeat(40) },
    autoCreateOwnerComments: {
      enabled: true,
      policyPath,
      policySha256: createHash("sha256").update(policyEnvelope).digest("hex"),
    },
  });

  const automaticIntent = {
    schemaVersion: 1,
    kind: "owner-v2-service-create-intent",
    runId: "run-auto",
    state: { identity },
    subject: {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
    },
    implementation: {
      toolkitHead: "f".repeat(40),
      toolkitTree: "1".repeat(40),
      formatterSha256,
    },
    selections: [{
      findingId,
      marker,
      path: "tests/Widget Tests.cs",
      line: 12,
      symbol: "<script>alert(1)</script>",
      body,
      bodySha256,
    }],
    createdUtc: "20260924T200000Z",
  };
  await write(join(deliveryRoot, "intents", identity, "run-auto.json"), signedEnvelope(automaticIntent, serviceKey));
  await write(join(deliveryRoot, "events", "event-auto.json"), signedEnvelope({
    schemaVersion: 1,
    kind: "owner-v2-delivery-event",
    eventId: "event-auto",
    runId: "run-auto",
    occurredUtc: "20260924T200100Z",
    runHealth: "healthy",
    subject: {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
      sourceCommit: "d".repeat(40),
      targetCommit: "2".repeat(40),
      targetRef: "refs/heads/main",
    },
    finding: {
      stateIdentity: identity,
      findingId,
      marker,
      path: "tests/Widget Tests.cs",
      line: 12,
      symbol: "<script>alert(1)</script>",
    },
    action: "create",
    outcome: "created",
    threadId: 100,
    commentId: 101,
    url: "https://foreign.example.invalid/",
    modelWriteCount: 0,
    providerWriteCount: 1,
    providerWriteState: "confirmed",
    diagnostic: null,
  }, serviceKey));

  const manualInvocation = "manual-run";
  await write(join(manualRoot, "intents", identity, `${manualInvocation}.json`), signedEnvelope({
    schemaVersion: 1,
    kind: "owner-v2-comment-intent",
    invocationId: manualInvocation,
    stateIdentity: identity,
    publish: true,
    selections: [{
      findingId,
      marker,
      path: "tests/Widget Tests.cs",
      line: 12,
      symbol: "<script>alert(1)</script>",
      body,
      bodySha256,
    }],
    createdUtc: "20260924T190000Z",
  }, manualKey));
  await write(join(manualRoot, "outcomes", identity, `${manualInvocation}.json`), signedEnvelope({
    schemaVersion: 1,
    kind: "owner-v2-comment-outcome",
    invocationId: manualInvocation,
    stateIdentity: identity,
    status: "completed",
    providerWrites: 1,
    results: [{ findingId, marker, outcome: "created", bodySha256, providerWrites: 1 }],
    createdUtc: "20260924T190100Z",
  }, manualKey));

  const scheduledRunFixture = JSON.parse(await readFile(
    join(process.cwd(), "test", "fixtures", "owner-relation-scheduled-run.json"), "utf8",
  ));
  await writeJson(join(runnerRoot, "last-run.json"), scheduledRunFixture);
  const logLines = Array.from({ length: 20 }, (_, index) => JSON.stringify({
    schemaVersion: 1,
    kind: "devpilot-owner-reporting-run-projection",
    runId: `scheduled-${index}`,
    health: index === 0 ? "refused" : "healthy",
    completedUtc: `2026-09-${String(index + 1).padStart(2, "0")}T00:00:00Z`,
    attempts: 1,
    modelCalls: 1,
    owner: { completed: 1, failed: 0 },
    relation: { completed: 1, failed: 0 },
    queue: { pending: 0, posted: index % 2 },
    providerWrites: index % 2,
    modelWrites: 0,
    deliveryOutcome: index === 0 ? "refused" : "healthy",
    diagnostic: "",
  })).join("\n");
  await write(join(runnerRoot, "scheduled-runs.jsonl"), `${logLines}\n`);

  const configPath = join(root, "reporting.json");
  await writeJson(configPath, {
    schemaVersion: 1,
    kind: "devpilot-owner-reporting-config",
    roots: {
      state: stateRoot,
      toolkit: toolkitRoot,
      config: toolkitRoot,
      delivery: deliveryRoot,
      manual: manualRoot,
      runner: runnerRoot,
    },
    files: {
      toolkitConfig: toolkitConfigPath,
      lastRun: join(runnerRoot, "last-run.json"),
      scheduledLog: join(runnerRoot, "scheduled-runs.jsonl"),
    },
    expectedToolkit: { head: "f".repeat(40), tree: "1".repeat(40) },
    azureDevOps: {
      organizationUrl: "https://dev.azure.com/example",
      projectId: "11111111-1111-1111-1111-111111111111",
      projectName: "Example Project",
      repositoryId: "22222222-2222-2222-2222-222222222222",
    },
    scheduledTaskName: "DevPilot Owner v2",
    refreshIntervalSeconds: 30,
    staleAfterMinutes: 120,
    budgets: {
      maxFileBytes: 1_048_576,
      maxFiles: 2_000,
      maxHistory: options.maxHistory ?? 50,
      maxScanMilliseconds: 5_000,
    },
  });
  return {
    root, configPath, stateRoot, toolkitRoot, deliveryRoot, manualRoot, runnerRoot,
    serviceKey, manualKey, identity, findingId, marker, body,
  };
}

test("Azure DevOps links validate identities, encode segments, and add discussion/file anchors", () => {
  const links = buildAzureDevOpsLinks({
    organizationUrl: "https://dev.azure.com/example",
    projectName: "Project Name",
    expectedProjectId: "project-id",
    expectedRepositoryId: "repo-id",
    projectId: "project-id",
    repositoryId: "repo-id",
    pullRequestId: 42,
    threadId: 100,
    commentId: 101,
    path: "tests/Widget Tests.cs",
    line: 12,
  });

  assert.match(links.prUrl, /Project%20Name/);
  assert.match(links.commentUrl ?? "", /discussionId=100/);
  assert.match(links.commentUrl ?? "", /commentId=101/);
  assert.match(links.commentUrl ?? "", /path=%2Ftests%2FWidget/);
  assert.throws(() => buildAzureDevOpsLinks({
    organizationUrl: "https://evil.example.com/org",
    projectName: "Project",
    expectedProjectId: "project-id",
    expectedRepositoryId: "repo-id",
    projectId: "project-id",
    repositoryId: "repo-id",
    pullRequestId: 42,
  }), /organization host/);
  assert.throws(() => buildAzureDevOpsLinks({
    organizationUrl: "https://dev.azure.com/example",
    projectName: "Project",
    expectedProjectId: "project-id",
    expectedRepositoryId: "repo-id",
    projectId: "foreign",
    repositoryId: "repo-id",
    pullRequestId: 42,
  }), /foreign/);
  assert.throws(() => buildAzureDevOpsLinks({
    organizationUrl: "https://dev.azure.com/example",
    projectName: "Project",
    expectedProjectId: "project-id",
    expectedRepositoryId: "repo-id",
    projectId: "project-id",
    repositoryId: "repo-id",
    pullRequestId: 42,
    threadId: 1,
    path: "../secret",
    line: 1,
  }), /file path/);
});

test("reporting config paths resolve locally and scheduled task names are exact", () => {
  assert.doesNotThrow(() => new LocalReportingAdapter("relative-reporting.json"));
  const base = {
    schemaVersion: 1,
    kind: "devpilot-owner-reporting-config",
    roots: {
      state: join(process.cwd(), "reporting-config-example", "state"),
      toolkit: join(process.cwd(), "reporting-config-example", "toolkit"),
      config: join(process.cwd(), "reporting-config-example", "config"),
    },
    files: { toolkitConfig: join(process.cwd(), "reporting-config-example", "config", "toolkit.json") },
    scheduledTaskName: "DevPilot Owner *",
    refreshIntervalSeconds: 30,
    staleAfterMinutes: 120,
    budgets: { maxFileBytes: 1_048_576, maxFiles: 100, maxHistory: 50, maxScanMilliseconds: 5_000 },
  };
  assert.throws(() => parseReportingConfiguration(base), /exact task name/);
  const withIntake = {
    ...base,
    scheduledTaskName: "DevPilot Owner v2",
    roots: { ...base.roots, intake: join(process.cwd(), "reporting-config-example", "intake") },
  };
  assert.throws(() => parseReportingConfiguration(withIntake), /configured together/);
  assert.throws(() => parseReportingConfiguration({
    ...base,
    scheduledTaskName: "DevPilot Owner v2",
    files: { ...base.files, intakeCohort: join(process.cwd(), "reporting-config-example", "intake", "cohort.json") },
  }), /configured together/);
});

function syntheticIntake(size = 347): JsonRecord {
  const heads = Array.from({ length: size }, (_, index) => ({
    pullRequestId: index + 1,
    sourceCommit: index < 20 ? (index + 1).toString(16).padStart(40, "0") : null,
    targetCommit: index < 20 ? "a".repeat(40) : null,
    targetRef: index < 275 ? "refs/heads/master" : "refs/heads/release",
    iterationId: index < 20 ? 21 : null,
    status: index < 275 ? "pending" : "skipped",
    reason: index < 275 ? "awaiting-scheduled-observation" : "target-out-of-policy",
    rules: [{
      capabilityId: "bpm-future-rule@1", ruleId: "future-rule",
      status: index < 275 ? "pending" : "skipped",
      reasonCode: index < 275 ? "no-evaluator" : "target-out-of-policy",
    }],
  }));
  return {
    schemaVersion: 1, kind: "active-pr-intake-cohort",
    generation: "f".repeat(32),
    generationFile: join("generations", `${"f".repeat(32)}.json`),
    observedUtc: "2026-09-24T21:00:00.000Z",
    binding: {
      organization: "https://dev.azure.com/example",
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
    },
    inventory: {
      state: "complete", discovered: size,
      eligible: Math.min(size, 275),
      excludedOtherTargets: Math.max(0, size - 275),
    },
    heads,
    rules: [{
      capabilityId: "bpm-future-rule@1",
      ruleId: "future-rule",
      discovered: size,
      eligible: Math.min(size, 275),
      evaluated: 0,
      skipped: Math.max(0, size - 275),
      error: 0,
      pending: Math.min(size, 275),
      gaps: ["scheduled-execution-not-wired"],
    }],
    gaps: ["scheduled-execution-not-wired"],
  };
}

test("read-only intake reports 347 distinct heads, excluded targets, and generic rules without fabricated evaluation", async () => {
  const feed = syntheticIntake();
  const first = (feed.heads as JsonRecord[])[0]!;
  asObject(feed.binding).configDigest = "c".repeat(64);
  first.declaration = {
    repositoryId: asObject(feed.binding).repositoryId,
    projectId: asObject(feed.binding).projectId,
    pullRequestId: first.pullRequestId, sourceRef: "refs/heads/feature",
    targetRef: first.targetRef, sourceCommit: first.sourceCommit,
    targetCommit: first.targetCommit, commonCommit: "b".repeat(40),
    iterationId: first.iterationId, status: "active", isDraft: false,
  };
  first.declarationDigest = createHash("sha256").update(JSON.stringify(first.declaration)).digest("hex");
  first.lineEvidence = {
    generation: feed.generation, declarationDigest: first.declarationDigest,
    configDigest: asObject(feed.binding).configDigest, baseCommit: "b".repeat(40),
    changedFiles: 1, changedLines: 3, addedLines: 2, deletedLines: 1,
    files: [{ pathDigest: "a".repeat(64), originalPathDigest: null,
      changeType: "edit", addedLines: 2, deletedLines: 1, newLineCount: 6,
      spans: [{ startLine: 3, endLine: 4 }] }],
  };
  first.lineEvidenceDigest = createHash("sha256").update(JSON.stringify(first.lineEvidence)).digest("hex");
  const parsed = parseIntakeCohort(feed);
  assert.equal(parsed.discovered, 347);
  assert.equal(parsed.eligible, 275);
  assert.equal(parsed.excludedOtherTargets, 72);
  assert.equal(parsed.rules[0]?.evaluated, 0);
  assert.equal(parsed.heads[0]?.lineEvidence?.changedLines, 3);
  const fixture = await createFixture();
  try {
    const intakeRoot = join(fixture.root, "intake");
    const intakeFile = join(intakeRoot, "cohort.json");
    await writeJson(intakeFile, feed);
    await writeJson(join(intakeRoot, "generations", `${"f".repeat(32)}.json`), feed);
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.roots).intake = intakeRoot;
    asObject(config.files).intakeCohort = intakeFile;
    await writeJson(fixture.configPath, config);
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T21:05:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(snapshot.intake?.state, "complete");
    assert.equal(reportingRows(snapshot, "intake").length, 347);
    assert.match(reportingRows(snapshot, "intake")[0]?.text.join(" ") ?? "",
      /Verified changed lines 3.*new-side 3-4/);
    assert.match(overviewLines(snapshot).join(" "), /discovered 347 \/ eligible master 275 \/ excluded other targets 72/);
    const generic = snapshot.rules?.find((rule) => rule.id === "future-rule");
    assert.equal(generic?.implemented, false);
    assert.equal(generic?.execution, "unknown");
    assert.equal(generic?.publishing, "unknown");
    assert.equal(generic?.intake?.evaluated, 0);
    assert.equal(generic?.lastEvaluatedUtc, null);
    assert.match(reportingRows(snapshot, "rules").at(-1)?.text.join(" ") ?? "", /evaluated 0.*pending 275/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("intake line evidence fails closed on mismatched binding, totals and out-of-range spans", () => {
  const feed = syntheticIntake(1);
  const head = (feed.heads as JsonRecord[])[0]!;
  asObject(feed.binding).configDigest = "c".repeat(64);
  head.declaration = {
    repositoryId: asObject(feed.binding).repositoryId,
    projectId: asObject(feed.binding).projectId,
    pullRequestId: 1, sourceRef: "refs/heads/feature",
    targetRef: head.targetRef, sourceCommit: head.sourceCommit,
    targetCommit: head.targetCommit, commonCommit: "b".repeat(40),
    iterationId: 21, status: "active", isDraft: false,
  };
  head.declarationDigest = createHash("sha256").update(JSON.stringify(head.declaration)).digest("hex");
  head.lineEvidence = {
    generation: feed.generation, declarationDigest: head.declarationDigest,
    configDigest: asObject(feed.binding).configDigest, baseCommit: "b".repeat(40),
    changedFiles: 1, changedLines: 2, addedLines: 1, deletedLines: 1,
    files: [{ pathDigest: "a".repeat(64), originalPathDigest: null,
      changeType: "edit", addedLines: 1, deletedLines: 1, newLineCount: 2,
      spans: [{ startLine: 2, endLine: 2 }] }],
  };
  head.lineEvidenceDigest = createHash("sha256").update(JSON.stringify(head.lineEvidence)).digest("hex");
  assert.equal(parseIntakeCohort(feed).heads[0]?.lineEvidence?.changedLines, 2);
  asObject(head.lineEvidence).changedLines = 0;
  assert.throws(() => parseIntakeCohort(feed), /binding/);
  head.lineEvidenceDigest = createHash("sha256").update(JSON.stringify(head.lineEvidence)).digest("hex");
  assert.throws(() => parseIntakeCohort(feed), /totals/);
  asObject(head.lineEvidence).changedLines = 2;
  asObject(head.lineEvidence).changedFiles = 0;
  asObject(head.lineEvidence).changedLines = 0;
  asObject(head.lineEvidence).addedLines = 0;
  asObject(head.lineEvidence).deletedLines = 0;
  asObject(head.lineEvidence).files = [];
  head.lineEvidenceDigest = createHash("sha256").update(JSON.stringify(head.lineEvidence)).digest("hex");
  assert.throws(() => parseIntakeCohort(feed), /totals/);
  asObject(head.lineEvidence).changedFiles = 1;
  asObject(head.lineEvidence).changedLines = 2;
  asObject(head.lineEvidence).addedLines = 1;
  asObject(head.lineEvidence).deletedLines = 1;
  asObject(head.lineEvidence).files = [{ pathDigest: "a".repeat(64),
    originalPathDigest: null, changeType: "edit", addedLines: 1,
    deletedLines: 1, newLineCount: 2, spans: [{ startLine: 2, endLine: 2 }] }];
  const span = ((asObject(head.lineEvidence).files as JsonRecord[])[0]!.spans as JsonRecord[])[0]!;
  span.endLine = 3;
  head.lineEvidenceDigest = createHash("sha256").update(JSON.stringify(head.lineEvidence)).digest("hex");
  assert.throws(() => parseIntakeCohort(feed), /span/);
  span.endLine = 2;
  asObject(head.lineEvidence).baseCommit = "f".repeat(40);
  head.lineEvidenceDigest = createHash("sha256").update(JSON.stringify(head.lineEvidence)).digest("hex");
  assert.throws(() => parseIntakeCohort(feed), /binding/);
});

test("intake fails closed on duplicate or drifting denominators, claimed evaluations, and missing feed", async () => {
  const duplicate = syntheticIntake();
  (duplicate.heads as JsonRecord[])[1]!.pullRequestId = 1;
  assert.throws(() => parseIntakeCohort(duplicate), /duplicate/);
  const truncated = syntheticIntake();
  (truncated.heads as JsonRecord[]).pop();
  assert.throws(() => parseIntakeCohort(truncated), /denominator/);
  const silent = syntheticIntake();
  ((silent.rules as JsonRecord[])[0]!).pending = 274;
  assert.throws(() => parseIntakeCohort(silent), /cannot claim evaluation/);
  const nonmaster = syntheticIntake();
  (nonmaster.heads as JsonRecord[])[275]!.status = "pending";
  assert.throws(() => parseIntakeCohort(nonmaster), /denominator/);
  const claimed = syntheticIntake();
  ((claimed.rules as JsonRecord[])[0]!).evaluated = 1;
  assert.throws(() => parseIntakeCohort(claimed), /cannot claim evaluation/);
  const injection = syntheticIntake();
  (injection.heads as JsonRecord[])[0]!.reason = "Bearer private-secret";
  assert.throws(() => parseIntakeCohort(injection), /reason code/);
  const fixture = await createFixture();
  try {
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.roots).intake = join(fixture.root, "intake");
    asObject(config.files).intakeCohort = join(fixture.root, "intake", "missing.json");
    await mkdir(join(fixture.root, "intake"));
    await writeJson(fixture.configPath, config);
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T21:05:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(snapshot.intake?.state, "unknown");
    assert.equal(snapshot.intake?.discovered, null);
    assert.deepEqual(snapshot.intake?.gaps, ["intake-file-unavailable"]);
    assert.equal(snapshot.rules?.length, 5);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("intake preserves inaccessible heads as explicit unknown without inventing commits or coverage", () => {
  const feed = syntheticIntake(1);
  feed.inventory = {
    state: "unknown", discovered: null, eligible: null, excludedOtherTargets: null,
  };
  feed.heads = [{
    pullRequestId: 1, sourceCommit: null, targetCommit: null,
    targetRef: "refs/heads/master", iterationId: null,
    status: "unknown", reason: "head-inaccessible",
    rules: [],
  }];
  feed.rules = [];
  feed.gaps = ["inaccessible-head"];
  const report = parseIntakeCohort(feed);
  assert.equal(report.state, "unknown");
  assert.equal(report.heads[0]?.iterationId, null);
  assert.equal(report.eligible, null);
  assert.equal(report.rules.length, 0);
});

test("intake reader rejects foreign paths and marks old inventory stale without changing verified rule observations", async () => {
  const fixture = await createFixture();
  try {
    const intakeRoot = join(fixture.root, "intake");
    const intakeFile = join(intakeRoot, "cohort.json");
    await writeJson(intakeFile, syntheticIntake());
    await writeJson(join(intakeRoot, "generations", `${"f".repeat(32)}.json`), syntheticIntake());
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.roots).intake = intakeRoot;
    asObject(config.files).intakeCohort = intakeFile;
    await writeJson(fixture.configPath, config);
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-27T21:05:00Z"),
      taskReader: async () => healthyTask,
    });
    const stale = await adapter.read();
    assert.equal(stale.intake?.state, "unknown");
    assert.ok(stale.intake?.gaps.includes("stale-inventory"));
    const wrongRepository = syntheticIntake();
    asObject(wrongRepository.binding).repositoryId = "33333333-3333-3333-3333-333333333333";
    await writeJson(intakeFile, wrongRepository);
    await writeJson(join(intakeRoot, "generations", `${"f".repeat(32)}.json`), wrongRepository);
    const mismatched = await adapter.read();
    assert.deepEqual(mismatched.intake?.gaps, ["invalid-intake-cohort"]);
    assert.equal(mismatched.intake?.discovered, null);
    asObject(config.files).intakeCohort = join(fixture.toolkitRoot, "owner-v2-config.json");
    await writeJson(fixture.configPath, config);
    const foreign = await adapter.read();
    assert.deepEqual(foreign.intake?.gaps, ["intake-path-untrusted"]);
    assert.equal(foreign.intake?.eligible, null);
    assert.equal(foreign.rules?.length, 5);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("reporting adapter verifies signed feeds, isolates relation findings, derives bodies, and bounds histories", async () => {
  const fixture = await createFixture({ maxHistory: 10 });
  try {
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => healthyTask,
    });
    const snapshot = await adapter.read();
    assert.equal(snapshot.overall.status, "healthy");
    assert.equal(snapshot.runs.length, 10);
    assert.equal(snapshot.findings.length, 1);
    assert.match(snapshot.findings[0]?.url ?? "", /pullrequest\/42/);
    assert.match(snapshot.findings[0]?.url ?? "", /discussionId=200/);
    assert.match(snapshot.findings[0]?.url ?? "", /commentId=201/);
    assert.equal(snapshot.relations.length, 1);
    assert.equal(snapshot.relations[0]?.writerEligible, false);
    assert.equal(snapshot.relations[0]?.url, null);
    assert.equal(snapshot.relations[0]?.reason,
      "Synthetic relation assessment is bound to the historical snapshot.");
    assert.equal(snapshot.relations[0]?.state, "violation");
    assert.equal(snapshot.relations[0]?.sourceCommit, "d".repeat(40));
    assert.equal(snapshot.deliveries.length, 2);
    const automatic = snapshot.deliveries.find((row) => row.mode === "automatic");
    const manual = snapshot.deliveries.find((row) => row.mode === "manual");
    assert.equal(automatic?.bodyStatus, "verified");
    assert.equal(automatic?.body, fixture.body);
    assert.equal(automatic?.providerWrites, 1);
    assert.match(automatic?.commentUrl ?? "", /dev\.azure\.com/);
    assert.doesNotMatch(automatic?.commentUrl ?? "", /foreign\.example/);
    assert.match(manual?.commentUrl ?? "", /discussionId=200/);
    assert.match(manual?.commentUrl ?? "", /commentId=201/);
    assert.equal(snapshot.overall.modelWrites, 0);
    assert.equal(snapshot.toolkit.matches, true);
    const compositeRun = snapshot.runs.find((run) => run.runId === "sanitized-live-run");
    assert.equal(compositeRun?.ownerCompleted, 1);
    assert.equal(compositeRun?.relationCompleted, 1);
    assert.equal(compositeRun?.attempts, 2);
    assert.equal(compositeRun?.modelCalls, null);
    assert.equal(compositeRun?.queuePosted, 9);
    const relationRows = reportingRows(snapshot, "relations");
    assert.match(relationRows[0]?.text.join(" ") ?? "", /NOT WRITER ELIGIBLE/);
    assert.match(relationRows[0]?.text.join(" ") ?? "", /STALE VERDICT.*current head not assessed/);
    assert.match(relationRows[0]?.text.join(" ") ?? "", /Violation explanation: Synthetic relation assessment/);
    assert.equal(relationRows[0]?.url, null);
    const deliveryRows = reportingRows(snapshot, "deliveries");
    assert.match(deliveryRows[0]?.text.join(" ") ?? "", /<script>alert\(1\)<\/script>/);
    assert.match(overviewLines(snapshot).join("\n"), /SERVICE HEALTHY/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("relation no-op assessments and absent explanations never masquerade as violations", async () => {
  const fixture = await createFixture();
  try {
    const path = join(fixture.stateRoot, "owner-v2-preview-state", "schema-1",
      "capabilities", "relation", "observations", `${"e".repeat(64)}.json`);
    const observation = JSON.parse(await readFile(path, "utf8")) as JsonRecord;
    const finding = (observation.findings as JsonRecord[])[0]!;
    const data = finding.data as JsonRecord;
    data.disposition = "noOp";
    delete data.explanation;
    await writeJson(path, observation);
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"), taskReader: async () => healthyTask,
    });
    const snapshot = await adapter.read();
    assert.equal(snapshot.relations[0]?.state, "noOp");
    assert.equal(snapshot.relations[0]?.reason, "");
    assert.match(reportingRows(snapshot, "relations")[0]?.text.join(" ") ?? "", /Assessment: not recorded/);
    assert.doesNotMatch(reportingRows(snapshot, "relations")[0]?.text.join(" ") ?? "", /Violation explanation/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rules registry separates source, deployment, enablement, evaluation and verified outcomes", async () => {
  const fixture = await createFixture();
  try {
    const runPath = join(fixture.runnerRoot, "last-run.json");
    const run = JSON.parse(await readFile(runPath, "utf8")) as JsonRecord;
    run.completedUtc = "2026-09-24T20:30:00Z";
    await writeJson(runPath, run);
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T21:05:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    assert.deepEqual(REPORTING_SECTIONS.slice(-2), ["rules", "intake"]);
    const rules = snapshot.rules ?? [];
    assert.deepEqual(rules.map((rule) => rule.id), [
      "mstest-owner", "synthetic-relation-rule-v1", "bpm-test-class-coverage@1",
      "bpm-redundant-method-coverage@1", "bpm-named-areequal-arguments@1",
    ]);
    const owner = rules[0]!;
    assert.equal(owner.implemented, true);
    assert.equal(owner.sourceRuleId, "## Claim ownership");
    assert.equal(owner.installedHead, "f".repeat(40));
    assert.equal(owner.pinnedHead, "f".repeat(40));
    assert.equal(owner.deployment, "verified");
    assert.equal(owner.enablement, "verified");
    assert.equal(owner.execution, "verified");
    assert.equal(owner.authorization, "enabled");
    assert.equal(owner.publishing, "enabled");
    assert.deepEqual(owner.policyCaps, { perRun: 5, perPullRequest: 25 });
    assert.equal(owner.lastGeneration, "sanitized-live-run");
    assert.deepEqual(owner.scope, [42]);
    assert.equal(owner.counts.finding, 1);
    assert.equal(owner.counts.noOp, 1);
    assert.equal(owner.counts.wouldCreate, 0);
    assert.equal(owner.counts.unknown, 0);
    assert.equal(owner.counts.skipped, null);
    assert.equal(owner.counts.posted, 2);
    assert.deepEqual(owner.deliveryIds.sort(), ["automatic:event-auto", "manual:manual-run:0"]);
    assert.match(owner.url ?? "", /discussionId=100/);
    const relation = rules[1]!;
    assert.equal(relation.deployment, "verified");
    assert.equal(relation.execution, "stale");
    assert.equal(relation.sourceRuleId, "synthetic-relation-rule-v1");
    assert.equal(relation.lastEvaluatedUtc, "2026-09-24T19:00:00.000Z");
    assert.equal(relation.authorization, "not-eligible");
    assert.equal(relation.publishing, "not-eligible");
    assert.equal(relation.counts.finding, 1);
    assert.equal(relation.counts.unknown, 0);
    assert.equal(relation.url, null);
    const classRule = rules[2]!;
    assert.equal(classRule.deployment, "not-deployed");
    assert.equal(classRule.enablement, "disabled");
    assert.equal(classRule.execution, "unknown");
    assert.equal(classRule.authorization, "disabled");
    assert.equal(classRule.publishing, "disabled");
    assert.equal(classRule.policyCaps, null);
    assert.equal(classRule.counts.finding, null);
    assert.equal(classRule.lastGeneration, null);
    assert.match(classRule.provenance, /588c0045/);
    assert.match(classRule.gaps.join(" "), /not deployed/i);
    const redundant = rules[3]!;
    assert.equal(redundant.implemented, true);
    assert.equal(redundant.deployment, "not-deployed");
    assert.equal(redundant.enablement, "disabled");
    assert.equal(redundant.execution, "unknown");
    assert.equal(redundant.authorization, "disabled");
    assert.equal(redundant.publishing, "disabled");
    assert.equal(redundant.policyCaps, null);
    assert.equal(redundant.counts.finding, null);
    assert.equal(redundant.counts.posted, null);
    assert.equal(redundant.lastGeneration, null);
    assert.deepEqual(redundant.scope, []);
    assert.match(redundant.gaps.join(" "), /not deployed in the pinned service/i);
    const named = rules[4]!;
    assert.equal(named.implemented, true);
    assert.equal(named.deployment, "not-deployed");
    assert.equal(named.enablement, "disabled");
    assert.equal(named.execution, "unknown");
    assert.equal(named.authorization, "disabled");
    assert.equal(named.publishing, "disabled");
    assert.equal(named.counts.finding, null);
    assert.equal(named.counts.posted, null);
    assert.equal(named.affectedCalls, null);
    assert.deepEqual(named.scope, []);
    const rows = reportingRows(snapshot, "rules");
    assert.equal(rows.length, 5);
    assert.equal(rows[1]?.relation?.id, snapshot.relations[0]?.id);
    assert.match(rows[2]!.text.join(" "), /finding unknown.*skipped unknown/);
    assert.match(rows[3]!.text.join(" "), /auto policy disabled.*auto-post disabled/);
    assert.equal(filterReportingRows(rows, {
      timeRange: "24h", search: "rule:synthetic-relation-rule outcome:verified",
      posting: "all", mode: "all",
    }).length, 1);
    assert.equal(filterReportingRows(rows, {
      timeRange: "all", search: "class-coverage", posting: "all", mode: "all",
    })[0]?.key, "rule:bpm-test-class-coverage@1");
    assert.equal(filterReportingRows(rows, {
      timeRange: "all", search: "rule:bpm-redundant-method-coverage@1", posting: "all", mode: "all",
    })[0]?.key, "rule:bpm-redundant-method-coverage@1");
    const taskOff = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T21:05:00Z"),
      taskReader: async () => ({ ...healthyTask, enabled: false }),
    }).read();
    assert.equal(taskOff.rules?.[0]?.authorization, "enabled");
    assert.equal(taskOff.rules?.[0]?.publishing, "disabled");
    assert.equal(taskOff.rules?.[1]?.publishing, "not-eligible");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rules fail closed on missing or malformed run, truncated feeds, and stale evaluations", async () => {
  const fixture = await createFixture();
  try {
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-26T00:35:00Z"),
      taskReader: async () => healthyTask,
    });
    const stale = await adapter.read();
    assert.equal(stale.rules?.[0]?.execution, "stale");
    assert.equal(stale.rules?.[0]?.lastGeneration, "sanitized-live-run");
    const path = join(fixture.runnerRoot, "last-run.json");
    const run = JSON.parse(await readFile(path, "utf8")) as JsonRecord;
    asArray(run.records)[0] && (asObject(asArray(run.records)[0]).identity = "invalid");
    await writeJson(path, run);
    const malformed = await adapter.read();
    assert.equal(malformed.rules?.[0]?.deployment, "unknown");
    assert.equal(malformed.rules?.[0]?.execution, "unknown");
    assert.equal(malformed.rules?.[0]?.counts.noOp, null);
    assert.equal(malformed.rules?.[0]?.counts.posted, null);
    assert.ok(malformed.rules?.[0]?.gaps.some((gap) => /missing, malformed/.test(gap)));
    asObject(asArray(run.records)[0]).identity = fixture.identity;
    await writeJson(path, run);
    const observationPath = join(fixture.stateRoot, "owner-v2-preview-state", "schema-1",
      "capabilities", "owner", "observations", `${fixture.identity}.json`);
    const observation = JSON.parse(await readFile(observationPath, "utf8")) as JsonRecord;
    asObject(asArray(observation.findings)[0]).reconciliation = { classification: "unexpected" };
    await writeJson(observationPath, observation);
    const invalidObservation = await adapter.read();
    assert.ok(invalidObservation.failures.some((item) => item.id === `rule-evidence:${fixture.identity}`));
    assert.equal(invalidObservation.rules?.[0]?.counts.finding, null);
    assert.equal(invalidObservation.rules?.[1]?.counts.finding, null);
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.budgets).maxHistory = 10;
    await writeJson(fixture.configPath, config);
    const truncated = await adapter.read();
    assert.equal(truncated.truncated, true);
    assert.equal(truncated.rules?.[1]?.counts.finding, null);
    assert.equal(truncated.rules?.[1]?.scope.length, 0);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rules reject drifted durable source bindings and ambiguous Owner aliases", async () => {
  const fixture = await createFixture();
  try {
    const root = join(fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities");
    const ownerFile = join(root, "owner", "observations", `${fixture.identity}.json`);
    const owner = JSON.parse(await readFile(ownerFile, "utf8")) as JsonRecord;
    asObject(owner.rule).section = "Different rule";
    await writeJson(ownerFile, owner);
    const adapter = createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    });
    const changedSection = await adapter.read();
    assert.ok(changedSection.failures.some((item) => item.id === `rule-binding:${fixture.identity}`));
    assert.equal(changedSection.rules?.[0]?.counts.finding, null);
    assert.equal(changedSection.rules?.[0]?.url, null);
    asObject(owner.rule).section = "## Claim ownership";
    await writeJson(ownerFile, owner);

    const relationIdentity = "e".repeat(64);
    const relationFile = join(root, "relation", "observations", `${relationIdentity}.json`);
    const relation = JSON.parse(await readFile(relationFile, "utf8")) as JsonRecord;
    asObject(relation.rule).digest = `v1:sha256:${"0".repeat(64)}`;
    await writeJson(relationFile, relation);
    const wrongDigest = await adapter.read();
    assert.ok(wrongDigest.failures.some((item) => item.id === `rule-binding:${relationIdentity}`));
    assert.equal(wrongDigest.relations[0]?.url, null);
    assert.equal(wrongDigest.rules?.[1]?.counts.finding, null);
    asObject(relation.rule).digest = `v1:sha256:${"5".repeat(64)}`;
    asObject(asObject(asArray(relation.findings)[0]).data).ruleId = "wrong-rule";
    await writeJson(relationFile, relation);
    const wrongFindingRule = await adapter.read();
    assert.ok(wrongFindingRule.failures.some((item) => item.id === `rule-binding:${relationIdentity}`));
    assert.equal(wrongFindingRule.relations[0]?.url, null);

    asObject(asObject(asArray(relation.findings)[0]).data).ruleId = "synthetic-relation-rule-v1";
    await writeJson(relationFile, relation);
    const otherIdentity = "7".repeat(64);
    const ownerBase = join(root, "owner");
    const declaration = JSON.parse(await readFile(
      join(ownerBase, "declarations", `${fixture.identity}.json`), "utf8",
    )) as JsonRecord;
    const record = JSON.parse(await readFile(
      join(ownerBase, "records", `${fixture.identity}.json`), "utf8",
    )) as JsonRecord;
    asObject(declaration.rule).section = "Other Owner convention";
    declaration.stateDigest = `v1:sha256:${otherIdentity}`;
    asObject(owner.rule).section = "Other Owner convention";
    record.identity = otherIdentity;
    record.stateDigest = declaration.stateDigest;
    await writeJson(join(ownerBase, "declarations", `${otherIdentity}.json`), declaration);
    await writeJson(join(ownerBase, "records", `${otherIdentity}.json`), record);
    await writeJson(join(ownerBase, "observations", `${otherIdentity}.json`), owner);
    await writeJson(ownerFile, {
      ...owner, rule: { ...asObject(owner.rule), section: "## Claim ownership" },
    });
    const ambiguous = await adapter.read();
    assert.ok(ambiguous.rules?.[0]?.gaps.some((gap) => /ambiguous/.test(gap)));
    assert.equal(ambiguous.rules?.[0]?.deployment, "unknown");
    assert.equal(ambiguous.rules?.[0]?.counts.noOp, null);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("coverage events show the bound class and rule while human-covered findings need review", async () => {
  const fixture = await createFixture();
  try {
    const identity = "9".repeat(64);
    const findingId = `coverage-v2:${"8".repeat(64)}`;
    const marker = "7".repeat(64);
    const body = "**Test class coverage exclusion missing**\n\nChanged MSTest class `MissingTests`.";
    const bodySha256 = sha256Text(body);
    const subject = {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
    };
    const head = { sourceCommit: "d".repeat(40) };
    const capabilityId = "bpm-test-class-coverage@1";
    const declaration = {
      kind: "owner-v2-preview-declaration",
      stateDigest: `v1:sha256:${identity}`,
      subject, head,
      target: { targetCommit: "2".repeat(40), targetRef: "refs/heads/main" },
      capability: { id: capabilityId, digest: `v1:sha256:${"6".repeat(64)}` },
      rule: { section: capabilityId, path: "rules/coverage.md", commit: head.sourceCommit },
    };
    const coverageRoot = join(fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "coverage");
    await writeJson(join(coverageRoot, "declarations", `${identity}.json`), declaration);
    await writeJson(join(coverageRoot, "records", `${identity}.json`), {
      identity, stateDigest: declaration.stateDigest, state: "completed",
      capabilityId, capabilityDigest: declaration.capability.digest,
      subjectDigest: canonicalDigest(subject), headDigest: canonicalDigest(head),
      modelExecutionState: "notAttempted", updatedUtc: "utc:2026-09-24T20:02:00Z",
    });
    await writeJson(join(coverageRoot, "observations", `${identity}.json`), {
      schemaVersion: 2, kind: "owner-observation", capability: capabilityId,
      subject: {
        projectId: null, repositoryId: subject.repositoryId, pullRequestId: 42,
        headCommit: head.sourceCommit, targetCommit: declaration.target.targetCommit,
        targetRef: declaration.target.targetRef,
      },
      rule: { section: capabilityId, path: declaration.rule.path, commit: head.sourceCommit },
      lifecycle: { status: "completed" },
      effects: { dedupe: { humanCovered: 1 } },
      findings: [{
        identity: findingId, disposition: "violation",
        anchor: { path: "tests/MissingTests.cs", line: 3, symbol: "MissingTests" },
        reconciliation: { classification: "wouldCreate", bodySha256 },
      }, {
        identity: `coverage-v2:${"5".repeat(64)}`, disposition: "violation",
        anchor: { path: "tests/HumanCoveredTests.cs", line: 24, symbol: "HumanCoveredTests" },
        reconciliation: {
          classification: "humanCovered", reason: "existing-human-discussion",
          thread: { availability: "available", status: "active", threadId: 300, commentId: 301 },
        },
      }, {
        identity: `coverage-v2:${"6".repeat(64)}`, disposition: "violation",
        anchor: { path: "tests/HistoricalTests.cs", line: 26, symbol: "HistoricalTests" },
        reconciliation: {
          classification: "unknown", reason: "historical-human-review-needs-review",
          thread: { availability: "available", status: "closed", threadId: 1001, commentId: 1002 },
        },
      }],
    });
    const formatterSha256 = sha256Text("formatter fixture\n");
    const coverageIntent = {
      schemaVersion: 1, kind: "coverage-v2-service-create-intent", runId: "run-coverage",
      state: { identity }, capability: { id: capabilityId }, rule: { section: capabilityId },
      subject: {
        ...subject, sourceCommit: head.sourceCommit,
        targetCommit: declaration.target.targetCommit, targetRef: declaration.target.targetRef,
      },
      implementation: {
        toolkitHead: "f".repeat(40), toolkitTree: "1".repeat(40), formatterSha256,
      },
      selections: [{
        findingId, marker, path: "tests/MissingTests.cs", line: 3, symbol: "MissingTests", body, bodySha256,
      }],
    };
    await write(join(fixture.deliveryRoot, "intents", identity, "run-coverage.json"),
      signedEnvelope(coverageIntent, fixture.serviceKey));
    const coverageEvent = {
      schemaVersion: 1, kind: "coverage-v2-delivery-event",
      eventId: "event-coverage", runId: "run-coverage", ruleId: capabilityId, capabilityId,
      occurredUtc: "20260924T200300Z", runHealth: "healthy",
      subject: {
        ...subject, sourceCommit: head.sourceCommit,
        targetCommit: declaration.target.targetCommit, targetRef: declaration.target.targetRef,
      },
      finding: {
        stateIdentity: identity, findingId, marker,
        path: "tests/MissingTests.cs", line: 3, symbol: "MissingTests",
      },
      action: "create", outcome: "created", threadId: 400, commentId: 401,
      providerWriteCount: 1, modelWriteCount: 0, providerWriteState: "confirmed",
    };
    await write(join(fixture.deliveryRoot, "events", "event-coverage.json"),
      signedEnvelope(coverageEvent, fixture.serviceKey));
    const historicalEvent = {
      ...coverageEvent,
      eventId: "event-coverage-historical",
      finding: {
        stateIdentity: identity, findingId: `coverage-v2:${"6".repeat(64)}`,
        marker: "e".repeat(64), path: "tests/HistoricalTests.cs", line: 26, symbol: "HistoricalTests",
      },
      action: "none", outcome: "refused", runHealth: "refused",
      threadId: 1001, commentId: 1002, providerWriteCount: 0,
      providerWriteState: "none",
      diagnostic: {
        code: "historical-human-review-needs-review",
        message: "Historical human coverage review (closed) needs operator review; no comment was created.",
      },
    };
    await write(join(fixture.deliveryRoot, "events", "event-coverage-historical.json"),
      signedEnvelope(historicalEvent, fixture.serviceKey));
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"), taskReader: async () => healthyTask,
    });
    const snapshot = await adapter.read();
    assert.equal(snapshot.deliveries.find((delivery) => delivery.eventId === "event-auto")?.bodyStatus,
      "verified");
    const coverage = snapshot.deliveries.find((delivery) => delivery.eventId === "event-coverage");
    assert.notEqual(snapshot.rules?.[2]?.deployment, "verified");
    assert.notEqual(snapshot.rules?.[2]?.execution, "verified");
    assert.equal(snapshot.rules?.[2]?.counts.posted, null);
    assert.equal(coverage?.capabilityId, capabilityId);
    assert.equal(coverage?.rule, capabilityId);
    assert.equal(coverage?.symbol, "MissingTests");
    assert.equal(coverage?.bodyStatus, "verified");
    assert.equal(coverage?.body, body);
    const deliveryRow = reportingRows(snapshot, "deliveries").find((row) => row.key === "automatic:event-coverage");
    assert.equal(deliveryRow?.capability, capabilityId);
    assert.match(deliveryRow?.text.join(" ") ?? "", /bpm-test-class-coverage@1.*MissingTests/);
    assert.equal(filterReportingRows(reportingRows(snapshot, "deliveries"), {
      timeRange: "all", search: "capability:class-coverage", posting: "posted", mode: "automatic",
    }).length, 1);

    const humanCovered = snapshot.findings.find((finding) => finding.symbol === "HumanCoveredTests");
    assert.equal(humanCovered?.state, "humanCovered");
    assert.doesNotMatch(humanCovered?.url ?? "", /discussionId|commentId/);
    const reviewRow = reportingRows(snapshot, "findings").find((row) => row.outcome === "humanCovered");
    assert.equal(reviewRow?.posting, "pending");
    assert.equal(reviewRow?.health, "needs-review");
    assert.equal(reviewRow?.attention, true);
    assert.match(reviewRow?.text.join(" ") ?? "", /humanCovered \(needs-review\)/);

    const historical = snapshot.findings.find((finding) => finding.symbol === "HistoricalTests");
    assert.equal(historical?.state, "unknown");
    assert.match(historical?.url ?? "", /discussionId=1001&commentId=1002/);
    const historicalFindingRow = reportingRows(snapshot, "findings").find((row) => row.key === `finding:${historical?.id}`);
    assert.equal(historicalFindingRow?.health, "needs-review");
    assert.equal(historicalFindingRow?.posting, "pending");
    assert.match(historicalFindingRow?.text.join(" ") ?? "", /unknown \(needs-review\)/);
    const refusal = snapshot.deliveries.find((delivery) => delivery.eventId === "event-coverage-historical");
    assert.equal(refusal?.action, "none");
    assert.equal(refusal?.outcome, "refused");
    assert.equal(refusal?.diagnosticCode, "historical-human-review-needs-review");
    assert.equal(refusal?.bodyStatus, "unavailable");
    assert.equal(refusal?.providerWrites, 0);
    assert.match(refusal?.commentUrl ?? "", /discussionId=1001&commentId=1002/);
    const refusalRow = reportingRows(snapshot, "deliveries").find((row) => row.key === "automatic:event-coverage-historical");
    assert.equal(refusalRow?.health, "needs-review");
    assert.equal(refusalRow?.posting, "pending");
    assert.match(refusalRow?.text.join(" ") ?? "", /historical-human-review-needs-review/);
    assert.ok(snapshot.failures.some((failure) => failure.id === "refused:event-coverage-historical" &&
      failure.category === "diagnostic"));

    await write(join(fixture.deliveryRoot, "events", "event-coverage-historical-mismatch.json"),
      signedEnvelope({ ...historicalEvent, eventId: "event-coverage-historical-mismatch", threadId: 999 },
        fixture.serviceKey));
    await write(join(fixture.deliveryRoot, "events", "event-coverage-no-intent.json"),
      signedEnvelope({ ...coverageEvent, eventId: "event-coverage-no-intent", runId: "missing-run" },
        fixture.serviceKey));
    await write(join(fixture.deliveryRoot, "events", "event-coverage-invalid-signature.json"),
      signedEnvelope({ ...coverageEvent, eventId: "event-coverage-invalid-signature" }, randomBytes(32)));
    await write(join(fixture.deliveryRoot, "events", "event-foreign-coverage.json"),
      signedEnvelope({ ...coverageEvent, eventId: "event-foreign-coverage", capabilityId: "bpm-test-ownership@1" },
        fixture.serviceKey));
    const invalid = await adapter.read();
    assert.equal(invalid.deliveries.some((delivery) => delivery.eventId === "event-coverage-historical-mismatch"), false);
    assert.ok(invalid.failures.some((failure) => failure.id === "event-binding:event-coverage-historical-mismatch"));
    assert.equal(invalid.deliveries.some((delivery) => delivery.eventId === "event-coverage-no-intent"), false);
    assert.ok(invalid.failures.some((failure) => failure.id === "event-binding:event-coverage-no-intent"));
    assert.equal(invalid.deliveries.some((delivery) => delivery.eventId === "event-coverage-invalid-signature"), false);
    assert.ok(invalid.quarantine.some((item) => item.file.endsWith("event-coverage-invalid-signature.json") &&
      /signature verification failed/.test(item.reason)));
    assert.equal(invalid.deliveries.some((delivery) => delivery.eventId === "event-foreign-coverage"), false);
    assert.ok(invalid.failures.some((failure) => failure.id === "event-binding:event-foreign-coverage"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("redundant method coverage remains independent of Owner and class deployment and delivery", async () => {
  const fixture = await createFixture();
  try {
    const capabilityId = "bpm-redundant-method-coverage@1";
    const identity = "9".repeat(64);
    const findingId = `redundant-coverage-v2:${"8".repeat(64)}`;
    const marker = "7".repeat(64);
    const body = "**Redundant method exclusions in WidgetTests**\n\nOne class comment covers 22 changed method attributes.";
    const bodySha256 = sha256Text(body);
    const affectedMethods = Array.from({ length: 12 }, (_, index) => `ShouldRun${index + 1}`);
    const affectedAttributeLines = Array.from({ length: 22 }, (_, index) => index + 17);
    const subject = {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
    };
    const head = { sourceCommit: "d".repeat(40) };
    const target = { targetCommit: "2".repeat(40), targetRef: "refs/heads/main" };
    const declaration = {
      kind: "owner-v2-preview-declaration", stateDigest: `v1:sha256:${identity}`,
      subject, head, target,
      capability: { id: capabilityId, digest: `v1:sha256:${"6".repeat(64)}` },
      rule: {
        section: capabilityId,
        path: "src/DevPilot.OwnerCapability/Policy/redundant-method-coverage.v1.txt",
        commit: "e".repeat(40),
      },
    };
    const root = join(fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "redundant");
    await writeJson(join(root, "declarations", `${identity}.json`), declaration);
    await writeJson(join(root, "records", `${identity}.json`), {
      identity, stateDigest: declaration.stateDigest, state: "completed",
      capabilityId, capabilityDigest: declaration.capability.digest,
      subjectDigest: canonicalDigest(subject), headDigest: canonicalDigest(head),
      updatedUtc: "utc:2026-09-24T20:02:00Z",
    });
    await writeJson(join(root, "observations", `${identity}.json`), {
      schemaVersion: 2, kind: "owner-observation", capability: capabilityId,
      subject: {
        projectId: null, repositoryId: subject.repositoryId, pullRequestId: subject.pullRequestId,
        headCommit: head.sourceCommit, ...target,
      },
      rule: { section: capabilityId, path: declaration.rule.path, commit: declaration.rule.commit },
      lifecycle: { status: "completed" },
      findings: [{
        identity: findingId, disposition: "violation",
        anchor: { path: "tests/WidgetTests.cs", line: 17, symbol: "WidgetTests" },
        affectedMethodCount: 22, affectedMethods, affectedAttributeLines, methodListTruncated: true,
        reconciliation: { classification: "wouldCreate", bodySha256 },
      }],
    });
    const signedSubject = { ...subject, sourceCommit: head.sourceCommit, ...target };
    const intent = {
      schemaVersion: 1, kind: "redundant-coverage-v2-service-create-intent",
      runId: "run-redundant", state: { identity },
      capability: { id: capabilityId }, rule: { section: capabilityId },
      subject: signedSubject,
      implementation: {
        toolkitHead: "f".repeat(40), toolkitTree: "1".repeat(40),
        formatterSha256: sha256Text("formatter fixture\n"),
      },
      selections: [{
        findingId, marker, path: "tests/WidgetTests.cs", line: 17,
        symbol: "WidgetTests", body, bodySha256,
      }],
    };
    await write(join(fixture.deliveryRoot, "intents", identity, "run-redundant.json"),
      signedEnvelope(intent, fixture.serviceKey));
    const event = {
      schemaVersion: 1, kind: "redundant-coverage-v2-delivery-event",
      eventId: "event-redundant", runId: "run-redundant", ruleId: capabilityId, capabilityId,
      occurredUtc: "20260924T200300Z", runHealth: "healthy", subject: signedSubject,
      finding: {
        stateIdentity: identity, findingId, marker,
        path: "tests/WidgetTests.cs", line: 17, symbol: "WidgetTests",
      },
      action: "create", outcome: "created", threadId: 400, commentId: 401,
      providerWriteCount: 1, modelWriteCount: 0, providerWriteState: "confirmed",
    };
    await write(join(fixture.deliveryRoot, "events", "event-redundant.json"),
      signedEnvelope(event, fixture.serviceKey));
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:35:00Z"), taskReader: async () => healthyTask,
    });
    const unbound = await adapter.read();
    const redundantFinding = unbound.findings.find((finding) => finding.id === findingId);
    assert.equal(redundantFinding?.rule, capabilityId);
    assert.equal(redundantFinding?.state, "wouldCreate");
    assert.equal(redundantFinding?.symbol, "WidgetTests");
    assert.equal(redundantFinding?.affectedMethodCount, 22);
    assert.deepEqual(redundantFinding?.affectedMethods, affectedMethods);
    assert.equal(redundantFinding?.methodListTruncated, true);
    const classFindingRow = reportingRows(unbound, "findings").find((row) => row.key === `finding:${findingId}`);
    assert.match(classFindingRow?.text.join(" ") ?? "", /One class finding \(at most one comment.*22 affected method attribute/);
    assert.match(classFindingRow?.text.join(" ") ?? "", /ShouldRun1.*ShouldRun12.*list truncated/);
    assert.match(redundantFinding?.url ?? "", /pullrequest\/42/);
    assert.equal(unbound.deliveries.find((delivery) => delivery.eventId === event.eventId)?.body, body);
    assert.equal(unbound.rules?.[3]?.counts.finding, null);
    assert.equal(unbound.rules?.[3]?.counts.posted, null);
    assert.equal(unbound.rules?.[3]?.deployment, "not-deployed");
    const runPath = join(fixture.runnerRoot, "last-run.json");
    const run = JSON.parse(await readFile(runPath, "utf8")) as JsonRecord;
    run.completedUtc = "2026-09-24T20:30:00Z";
    asObject(asArray(run.records)[0]).identity = identity;
    asObject(run.ownerAutoDelivery).kind = "coverage-v2-automatic-delivery-result";
    await writeJson(runPath, run);
    const classRun = await adapter.read();
    assert.equal(classRun.rules?.[3]?.execution, "unknown");
    assert.equal(classRun.rules?.[3]?.counts.finding, null);
    asObject(run.ownerAutoDelivery).kind = "redundant-coverage-v2-automatic-delivery-result";
    asObject(run.ownerAutoDelivery).runId = "run-redundant";
    await writeJson(runPath, run);
    const matched = await adapter.read();
    const rule = matched.rules?.[3];
    assert.equal(matched.runs[0]?.deliveryCapabilityId, capabilityId);
    assert.equal(rule?.deployment, "verified");
    assert.equal(rule?.execution, "verified");
    assert.equal(rule?.counts.finding, 1);
    assert.equal(rule?.affectedMethodAttributes, 22);
    assert.equal(rule?.counts.wouldCreate, 1);
    assert.equal(rule?.counts.posted, 1);
    assert.match(reportingRows(matched, "rules")[3]?.text.join(" ") ?? "",
      /Class outcomes: finding 1 class\(es\).*posted 1 class comment\(s\).*Affected method attributes across bound class findings: 22/);
    assert.equal(rule?.authorization, "unknown");
    assert.equal(rule?.publishing, "unknown");
    assert.equal(rule?.policyCaps, null);
    assert.deepEqual(rule?.deliveryIds, ["automatic:event-redundant"]);
    assert.equal(matched.rules?.[0]?.counts.finding, null);
    assert.match(reportingRows(matched, "runs")[0]?.text.join(" ") ?? "", /Redundant method coverage/);
    const confirmedCreate = matched.deliveries.find((delivery) => delivery.eventId === event.eventId)!;
    const projectedUpdate = projectRuleRegistry({
      ...matched,
      deliveries: [...matched.deliveries, {
        ...confirmedCreate, id: "automatic:event-updated", eventId: "event-updated",
        action: "update", outcome: "updated",
      }, {
        ...confirmedCreate, id: "automatic:event-updated-outcome",
        eventId: "event-updated-outcome", outcome: "updated",
      }],
    }, [{
      identity, capabilityId, ruleId: capabilityId, pullRequestId: 42,
      evaluatedUtc: redundantFinding!.updatedUtc, findingIds: [findingId],
      findings: 1, affectedMethodAttributes: 22, noOp: 0, wouldCreate: 1, unknown: 0,
    }], 120, { automatic: true, manual: true })[3]!;
    assert.equal(projectedUpdate.counts.posted, 1);
    assert.deepEqual(projectedUpdate.deliveryIds, ["automatic:event-redundant"]);
    await write(join(fixture.deliveryRoot, "events", "event-updated.json"),
      signedEnvelope({ ...event, eventId: "event-updated", action: "update", outcome: "updated" },
        fixture.serviceKey));
    const updated = await adapter.read();
    assert.equal(updated.deliveries.some((delivery) => delivery.eventId === "event-updated"), false);
    assert.ok(updated.failures.some((failure) => failure.id === "event-binding:event-updated" &&
      /create-only/.test(failure.message)));
    assert.equal(updated.rules?.[3]?.counts.posted, null);
    await rm(join(fixture.deliveryRoot, "events", "event-updated.json"));
    await write(join(fixture.deliveryRoot, "intents", identity, "run-other.json"),
      signedEnvelope({ ...intent, runId: "run-other" }, fixture.serviceKey));
    await write(join(fixture.deliveryRoot, "events", "event-other-run.json"),
      signedEnvelope({ ...event, eventId: "event-other-run", runId: "run-other" }, fixture.serviceKey));
    const otherRun = await adapter.read();
    assert.ok(otherRun.deliveries.some((delivery) => delivery.eventId === "event-other-run"));
    assert.equal(otherRun.rules?.[3]?.counts.posted, 1);
    assert.deepEqual(otherRun.rules?.[3]?.deliveryIds, ["automatic:event-redundant"]);
    const observationPath = join(root, "observations", `${identity}.json`);
    const observation = JSON.parse(await readFile(observationPath, "utf8")) as JsonRecord;
    asObject(observation.rule).section = "bpm-test-class-coverage@1";
    await writeJson(observationPath, observation);
    const foreignRule = await adapter.read();
    assert.equal(foreignRule.findings.some((finding) => finding.id === findingId), false);
    assert.ok(foreignRule.failures.some((failure) => failure.id === `rule-binding:${identity}`));
    assert.equal(foreignRule.rules?.[3]?.counts.finding, null);
    asObject(observation.rule).section = capabilityId;
    await writeJson(observationPath, observation);
    asObject(asArray(observation.findings)[0]).affectedMethods = ["ShouldRun", "<script>"];
    await writeJson(observationPath, observation);
    const malformedSummary = await adapter.read();
    assert.equal(malformedSummary.findings.some((finding) => finding.id === findingId), false);
    assert.ok(malformedSummary.failures.some((failure) => failure.id === `rule-binding:${identity}`));
    assert.equal(malformedSummary.rules?.[3]?.affectedMethodAttributes, null);
    asObject(asArray(observation.findings)[0]).affectedMethods = affectedMethods;
    await writeJson(observationPath, observation);
    observation.findings = [...asArray(observation.findings), {
      ...asObject(asArray(observation.findings)[0]),
      identity: `redundant-coverage-v2:${"5".repeat(64)}`,
    }];
    await writeJson(observationPath, observation);
    const duplicatedClass = await adapter.read();
    assert.equal(duplicatedClass.findings.some((finding) => finding.id === findingId), false);
    assert.ok(duplicatedClass.failures.some((failure) => failure.id === `rule-binding:${identity}`));
    assert.equal(duplicatedClass.rules?.[3]?.counts.finding, null);
    observation.findings = asArray(observation.findings).slice(0, 1);
    await writeJson(observationPath, observation);
    await write(join(fixture.deliveryRoot, "events", "event-redundant-bad.json"),
      signedEnvelope({ ...event, eventId: "event-redundant-bad",
        subject: { ...signedSubject, sourceCommit: "e".repeat(40) } }, fixture.serviceKey));
    const drifted = await adapter.read();
    assert.equal(drifted.deliveries.some((delivery) => delivery.eventId === "event-redundant-bad"), false);
    assert.ok(drifted.failures.some((failure) => failure.id === "event-binding:event-redundant-bad"));
    assert.equal(drifted.rules?.[3]?.counts.posted, null);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("named AreEqual source findings stay undeployed until a separate matching run binds method counts", async () => {
  const fixture = await createFixture();
  try {
    const capabilityId = "bpm-named-areequal-arguments@1";
    const identity = "9".repeat(64);
    const findingId = `named-areequal-v2:${"8".repeat(64)}`;
    const marker = "7".repeat(64);
    const path = "tests/WidgetTests.cs";
    const symbol = "WidgetTests.ShouldCompare";
    const body = "**Use named arguments for Assert.AreEqual in this test method**\n\nChanged calls: 2.";
    const bodySha256 = sha256Text(body);
    const subject = {
      projectId: "11111111-1111-1111-1111-111111111111",
      repositoryId: "22222222-2222-2222-2222-222222222222",
      pullRequestId: 42,
    };
    const head = { sourceCommit: "d".repeat(40) };
    const target = { targetCommit: "2".repeat(40), targetRef: "refs/heads/main" };
    const declaration = {
      kind: "owner-v2-preview-declaration", stateDigest: `v1:sha256:${identity}`,
      subject, head, target,
      capability: { id: capabilityId, digest: `v1:sha256:${"6".repeat(64)}` },
      rule: { section: capabilityId,
        path: "src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt",
        commit: "e".repeat(40) },
    };
    const root = join(fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "named-areequal");
    const namedDeliveryRoot = join(fixture.deliveryRoot, "named-areequal-v1");
    const namedKey = randomBytes(32);
    const namedKeyPath = join(namedDeliveryRoot, "keys", "named-areequal-service-authorization.hmac");
    await write(namedKeyPath, namedKey);
    await chmod(namedKeyPath, 0o600);
    const observationPath = join(root, "observations", `${identity}.json`);
    const finding = {
      identity: findingId, disposition: "violation",
      anchor: { path, line: 17, symbol },
      affectedCallCount: 2, affectedCallLines: [17, 24], callListTruncated: false,
      reconciliation: { classification: "wouldCreate", bodySha256 },
    };
    const observation = {
      schemaVersion: 2, kind: "owner-observation", capability: capabilityId,
      subject: { projectId: null, repositoryId: subject.repositoryId,
        pullRequestId: subject.pullRequestId, headCommit: head.sourceCommit, ...target },
      rule: { section: capabilityId, path: declaration.rule.path, commit: declaration.rule.commit },
      lifecycle: { status: "completed" }, findings: [finding],
    };
    await writeJson(join(root, "declarations", `${identity}.json`), declaration);
    await writeJson(join(root, "records", `${identity}.json`), {
      identity, stateDigest: declaration.stateDigest, state: "completed",
      capabilityId, capabilityDigest: declaration.capability.digest,
      subjectDigest: canonicalDigest(subject), headDigest: canonicalDigest(head),
      updatedUtc: "utc:2026-09-24T20:02:00Z",
    });
    await writeJson(observationPath, observation);
    const signedSubject = { ...subject, sourceCommit: head.sourceCommit, ...target };
    const intent = {
      schemaVersion: 1, kind: "named-areequal-v2-service-create-intent",
      runId: "run-named", state: { identity }, capability: { id: capabilityId },
      rule: { section: capabilityId }, subject: signedSubject,
      implementation: { toolkitHead: "f".repeat(40), toolkitTree: "1".repeat(40),
        formatterSha256: sha256Text("formatter fixture\n") },
      selections: [{
        findingId, marker, markerComment: `<!-- devpilot-named-areequal:v1:${marker} -->`,
        path, line: 17, symbol, body, bodySha256, classification: "wouldCreate",
        affectedCallCount: 2, affectedCallLines: [17, 24], callListTruncated: false,
      }],
    };
    await write(join(namedDeliveryRoot, "intents", identity, "run-named.json"),
      signedEnvelope(intent, namedKey));
    const event = {
      schemaVersion: 1, kind: "named-areequal-v2-delivery-event",
      eventId: "event-named", runId: "run-named", ruleId: capabilityId, capabilityId,
      occurredUtc: "20260924T200300Z", runHealth: "healthy", subject: signedSubject,
      finding: { stateIdentity: identity, findingId, marker, bodySha256, path, line: 17, symbol },
      action: "create", outcome: "created", threadId: 400, commentId: 401,
      providerWriteCount: 1, modelWriteCount: 0, providerWriteState: "confirmed",
    };
    const eventPath = join(namedDeliveryRoot, "events", "event-named.json");
    await write(eventPath, signedEnvelope(event, namedKey));
    const adapter = createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:35:00Z"), taskReader: async () => healthyTask,
    });
    const unbound = await adapter.read();
    const source = unbound.rules?.[4];
    assert.equal(source?.deployment, "not-deployed");
    assert.equal(source?.execution, "unknown");
    assert.equal(source?.counts.finding, null);
    assert.equal(source?.affectedCalls, null);
    assert.equal(source?.counts.posted, null);
    assert.equal(unbound.rules?.[0]?.counts.finding, 1);
    const findingRow = unbound.findings.find((item) => item.id === findingId);
    assert.deepEqual(findingRow?.affectedCallLines, [17, 24]);
    assert.equal(findingRow?.affectedCallCount, 2);
    assert.equal(findingRow?.state, "wouldCreate");
    assert.match(findingRow?.url ?? "", /pullrequest\/42/);
    const delivery = unbound.deliveries.find((item) => item.eventId === event.eventId);
    assert.equal(delivery?.bodyStatus, "verified");
    assert.equal(delivery?.body, body);
    assert.match(delivery?.commentUrl ?? "", /discussionId=400/);
    const runPath = join(fixture.runnerRoot, "last-run.json");
    const run = JSON.parse(await readFile(runPath, "utf8")) as JsonRecord;
    run.completedUtc = "2026-09-24T20:30:00Z";
    asObject(asArray(run.records)[0]).identity = identity;
    asObject(run.ownerAutoDelivery).kind = "redundant-coverage-v2-automatic-delivery-result";
    await writeJson(runPath, run);
    const otherChannel = await adapter.read();
    assert.equal(otherChannel.rules?.[4]?.counts.finding, null);
    asObject(run.ownerAutoDelivery).kind = "named-areequal-v2-automatic-delivery-result";
    asObject(run.ownerAutoDelivery).runId = "run-named";
    await writeJson(runPath, run);
    const bound = await adapter.read();
    const named = bound.rules?.[4];
    assert.equal(bound.runs[0]?.deliveryCapabilityId, capabilityId);
    assert.equal(named?.deployment, "verified");
    assert.equal(named?.execution, "verified");
    assert.equal(named?.counts.finding, 1);
    assert.equal(named?.counts.wouldCreate, 1);
    assert.equal(named?.affectedCalls, 2);
    assert.equal(named?.counts.posted, 1);
    assert.equal(named?.authorization, "disabled");
    assert.equal(named?.publishing, "disabled");
    assert.equal(named?.policyCaps, null);
    assert.deepEqual(named?.deliveryIds, ["automatic:event-named"]);
    assert.equal(bound.rules?.[0]?.counts.finding, null);
    const impostorPath = join(fixture.deliveryRoot, "events", "event-named-owner-key.json");
    await write(impostorPath, signedEnvelope({
      ...event, eventId: "event-named-owner-key",
    }, fixture.serviceKey));
    const wrongKeyRoot = await adapter.read();
    assert.equal(wrongKeyRoot.deliveries.some((item) => item.eventId === "event-named-owner-key"), false);
    assert.ok(wrongKeyRoot.quarantine.some((item) => item.file.endsWith("event-named-owner-key.json")));
    await rm(impostorPath);
    await rm(namedKeyPath);
    const unavailableNamedFeed = await adapter.read();
    assert.equal(unavailableNamedFeed.rules?.[4]?.counts.posted, null);
    assert.ok(unavailableNamedFeed.diagnostics.some((item) =>
      item.startsWith("named AreEqual delivery feed unavailable:")));
    await write(namedKeyPath, namedKey);
    await chmod(namedKeyPath, 0o600);
    await write(join(namedDeliveryRoot, "events", "event-named-update.json"),
      signedEnvelope({ ...event, eventId: "event-named-update",
        action: "update", outcome: "updated" }, namedKey));
    const updated = await adapter.read();
    assert.equal(updated.deliveries.some((item) => item.eventId === "event-named-update"), false);
    assert.ok(updated.failures.some((item) => item.id === "event-binding:event-named-update" &&
      /create-only/.test(item.message)));
    assert.equal(updated.rules?.[4]?.counts.posted, null);
    await rm(join(namedDeliveryRoot, "events", "event-named-update.json"));
    await write(join(namedDeliveryRoot, "events", "event-named-foreign.json"),
      signedEnvelope({ ...event, eventId: "event-named-foreign",
        capabilityId: "bpm-test-ownership@1" }, namedKey));
    const foreign = await adapter.read();
    assert.equal(foreign.deliveries.some((item) => item.eventId === "event-named-foreign"), false);
    assert.ok(foreign.failures.some((item) => item.id === "event-binding:event-named-foreign"));
    await rm(join(namedDeliveryRoot, "events", "event-named-foreign.json"));
    await write(join(namedDeliveryRoot, "events", "event-named-wrong-method.json"),
      signedEnvelope({ ...event, eventId: "event-named-wrong-method",
        finding: { ...event.finding, symbol: "WidgetTests.OtherMethod" } }, namedKey));
    const wrongMethod = await adapter.read();
    assert.equal(wrongMethod.deliveries.some((item) => item.eventId === "event-named-wrong-method"), false);
    assert.ok(wrongMethod.failures.some((item) => item.id === "event-binding:event-named-wrong-method"));
    await rm(join(namedDeliveryRoot, "events", "event-named-wrong-method.json"));
    await write(join(namedDeliveryRoot, "events", "event-named-wrong-body.json"),
      signedEnvelope({ ...event, eventId: "event-named-wrong-body",
        finding: { ...event.finding, bodySha256: "0".repeat(64) } }, namedKey));
    const wrongEventBody = await adapter.read();
    assert.equal(wrongEventBody.deliveries.some((item) => item.eventId === "event-named-wrong-body"), false);
    assert.ok(wrongEventBody.failures.some((item) => item.id === "event-binding:event-named-wrong-body"));
    await rm(join(namedDeliveryRoot, "events", "event-named-wrong-body.json"));
    await write(join(namedDeliveryRoot, "events", "event-named-refusal-wrong-body.json"),
      signedEnvelope({ ...event, eventId: "event-named-refusal-wrong-body",
        finding: { ...event.finding, bodySha256: "0".repeat(64) },
        action: "none", outcome: "refused", threadId: null, commentId: null,
        providerWriteCount: 0, providerWriteState: "none" }, namedKey));
    const wrongRefusalBody = await adapter.read();
    assert.equal(wrongRefusalBody.deliveries.some((item) =>
      item.eventId === "event-named-refusal-wrong-body"), false);
    assert.ok(wrongRefusalBody.failures.some((item) =>
      item.id === "event-binding:event-named-refusal-wrong-body"));
    await rm(join(namedDeliveryRoot, "events", "event-named-refusal-wrong-body.json"));
    const intentPath = join(namedDeliveryRoot, "intents", identity, "run-named.json");
    await write(intentPath, signedEnvelope({
      ...intent, selections: [{ ...intent.selections[0], body: `${body} Tampered.` }],
    }, namedKey));
    const wrongBody = await adapter.read();
    assert.equal(wrongBody.deliveries.some((item) => item.eventId === "event-named"), false);
    assert.ok(wrongBody.failures.some((item) => item.id === "event-binding:event-named" &&
      /body/.test(item.message)));
    await write(intentPath, signedEnvelope({
      ...intent, selections: [{ ...intent.selections[0], affectedCallCount: 3 }],
    }, namedKey));
    const wrongCallCount = await adapter.read();
    assert.equal(wrongCallCount.deliveries.some((item) => item.eventId === "event-named"), false);
    assert.ok(wrongCallCount.failures.some((item) => item.id === "event-binding:event-named"));
    await write(intentPath, signedEnvelope(intent, namedKey));
    await write(join(namedDeliveryRoot, "events", "event-named-tampered.json"),
      signedEnvelope({ ...event, eventId: "event-named-tampered" }, randomBytes(32)));
    const invalidSignature = await adapter.read();
    assert.ok(invalidSignature.quarantine.some((item) =>
      item.file.endsWith("event-named-tampered.json")));
    assert.equal(invalidSignature.deliveries.some((item) => item.eventId === "event-named-tampered"), false);
    await rm(join(namedDeliveryRoot, "events", "event-named-tampered.json"));
    finding.affectedCallLines = [17, 17];
    await writeJson(observationPath, observation);
    const malformed = await adapter.read();
    assert.ok(malformed.failures.some((item) => item.id === `rule-binding:${identity}`));
    assert.equal(malformed.findings.some((item) => item.id === findingId), false);
    assert.equal(malformed.rules?.[4]?.counts.finding, null);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("manual live audit links bind nine authoritative nested thread identities and reject ambiguity", async () => {
  const fixture = await createFixture();
  try {
    const liveFixture = JSON.parse(await readFile(
      join(process.cwd(), "test", "fixtures", "manual-nested-links.json"), "utf8",
    )) as JsonRecord;
    const observationPath = join(
      fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "owner",
      "observations", `${fixture.identity}.json`,
    );
    const observation = JSON.parse(await readFile(observationPath, "utf8")) as JsonRecord;
    const body = String(liveFixture.body);
    const bodySha256 = String(liveFixture.bodySha256);
    const fixtureFindings = asArray(liveFixture.findings).map(asObject);
    const findings = fixtureFindings.map((finding) => ({
        identity: finding.findingId,
        disposition: "violation",
        anchor: {
          path: finding.path,
          line: finding.line,
          symbol: finding.symbol,
        },
        reconciliation: {
          classification: "noOp",
          reason: "reviewer-marker-body-current",
          bodySha256,
          thread: {
            availability: "available",
            threadId: finding.threadId,
            commentId: finding.commentId,
            status: "active",
          },
        },
      }));
    const selections = fixtureFindings.map((finding) => ({
        findingId: finding.findingId,
        marker: finding.marker,
        path: finding.path,
        line: finding.line,
        symbol: finding.symbol,
        body,
        bodySha256,
      }));
    const results = fixtureFindings.map((finding) => ({
        findingId: finding.findingId,
        marker: finding.marker,
        outcome: "created",
        bodySha256,
        providerWrites: 1,
      }));
    observation.findings = findings;
    await writeJson(observationPath, observation);
    await rm(join(fixture.manualRoot, "intents", fixture.identity), { recursive: true, force: true });
    await rm(join(fixture.manualRoot, "outcomes", fixture.identity), { recursive: true, force: true });
    const invocationId = String(liveFixture.invocationId);
    await write(join(fixture.manualRoot, "intents", fixture.identity, `${invocationId}.json`), signedEnvelope({
      schemaVersion: 1,
      kind: "owner-v2-comment-intent",
      invocationId,
      stateIdentity: fixture.identity,
      publish: true,
      selections,
      createdUtc: "20260924T190000Z",
    }, fixture.manualKey));
    await write(join(fixture.manualRoot, "outcomes", fixture.identity, `${invocationId}.json`), signedEnvelope({
      schemaVersion: 1,
      kind: "owner-v2-comment-outcome",
      invocationId,
      stateIdentity: fixture.identity,
      status: "completed",
      providerWrites: 9,
      results,
      createdUtc: "20260924T190100Z",
    }, fixture.manualKey));

    const adapter = createAdapter(fixture.configPath, { taskReader: async () => healthyTask });
    const snapshot = await adapter.read();
    const published = snapshot.deliveries.filter((row) => row.mode === "manual" && row.outcome === "created");
    assert.equal(published.length, 9);
    assert.equal(published.filter((row) => row.commentUrl !== null).length, 9);
    assert.ok(published.every((row) => row.commentUrl?.includes(`discussionId=${row.threadId}`)));
    assert.equal(snapshot.findings.length, 9);
    assert.equal(snapshot.findings.filter((finding) => finding.url?.includes("discussionId=")).length, 9);

    const firstReconciliation = asObject(asObject(findings[0]).reconciliation);
    firstReconciliation.threadId = 9999;
    firstReconciliation.commentId = 9999;
    await writeJson(observationPath, observation);
    const ambiguous = await adapter.read();
    const first = ambiguous.deliveries.find((row) => row.mode === "manual" && row.outcome === "created" &&
      row.path === "tests/Synthetic1.cs");
    assert.equal(first?.commentUrl, null);
    assert.match(first?.diagnostic ?? "", /ambiguous/);

    delete firstReconciliation.thread;
    firstReconciliation.threadId = 1001;
    firstReconciliation.commentId = 2001;
    await writeJson(observationPath, observation);
    const legacy = await adapter.read();
    const legacyFirst = legacy.deliveries.find((row) => row.mode === "manual" && row.outcome === "created" &&
      row.path === "tests/Synthetic1.cs");
    assert.match(legacyFirst?.commentUrl ?? "", /discussionId=1001/);
    assert.match(legacyFirst?.commentUrl ?? "", /commentId=2001/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("pending findings use validated PR URLs and foreign identities fail closed", async () => {
  const fixture = await createFixture();
  try {
    const observationPath = join(
      fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "owner",
      "observations", `${fixture.identity}.json`,
    );
    const observation = JSON.parse(await readFile(observationPath, "utf8")) as JsonRecord;
    const finding = asObject(asArray(observation.findings)[0]);
    const reconciliation = asObject(finding.reconciliation);
    reconciliation.classification = "wouldCreate";
    reconciliation.reason = "reviewer-marker-not-found";
    delete reconciliation.thread;
    await writeJson(observationPath, observation);

    const pending = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.match(pending.findings[0]?.url ?? "", /pullrequest\/42/);
    assert.doesNotMatch(pending.findings[0]?.url ?? "", /discussionId|commentId/);

    const declarationPath = join(
      fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "owner",
      "declarations", `${fixture.identity}.json`,
    );
    const declaration = JSON.parse(await readFile(declarationPath, "utf8")) as JsonRecord;
    const declarationSubject = asObject(declaration.subject);
    const originalProjectId = declarationSubject.projectId;
    declarationSubject.projectId = "88888888-8888-8888-8888-888888888888";
    await writeJson(declarationPath, declaration);
    const mismatchedDeclaration = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(mismatchedDeclaration.findings[0]?.url, null);
    assert.ok(mismatchedDeclaration.failures.some((failure) =>
      /not fully bound/.test(failure.message)));
    declarationSubject.projectId = originalProjectId;
    await writeJson(declarationPath, declaration);

    const recordPath = join(
      fixture.stateRoot, "owner-v2-preview-state", "schema-1", "capabilities", "owner",
      "records", `${fixture.identity}.json`,
    );
    const record = JSON.parse(await readFile(recordPath, "utf8")) as JsonRecord;
    const originalIdentity = record.identity;
    record.identity = "f".repeat(64);
    await writeJson(recordPath, record);
    const mismatchedRecord = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(mismatchedRecord.findings[0]?.url, null);
    record.identity = originalIdentity;
    await writeJson(recordPath, record);

    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.azureDevOps).projectId = "99999999-9999-9999-9999-999999999999";
    await writeJson(fixture.configPath, config);
    const foreign = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(foreign.findings[0]?.url, null);
    assert.equal(foreign.relations[0]?.url, null);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("last-run parsing rejects unknown envelopes instead of manufacturing health", async () => {
  const fixture = await createFixture();
  try {
    await writeJson(join(fixture.runnerRoot, "last-run.json"), {
      schemaVersion: 1,
      kind: "unknown-run-envelope",
      health: "healthy",
    });
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    assert.ok(snapshot.diagnostics.some((message) => /last-run unavailable: run kind is unsupported/.test(message)));
    assert.equal(snapshot.overall.status, "degraded");
    assert.equal(snapshot.runs.some((run) => run.runId === "last-run"), false);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("composite run producer partial/failure and unknown reconciliation cannot surface healthy", async () => {
  const fixture = await createFixture();
  try {
    const path = join(fixture.runnerRoot, "last-run.json");
    const run = JSON.parse(await readFile(path, "utf8")) as JsonRecord;
    run.overallOutcome = "partial";
    asObject(asObject(run.ownerOperatorOutput).reconciliation).unknown = 1;
    asObject(asObject(run.ownerOperatorOutput).reconciliation).humanCovered = 2;
    await writeJson(path, run);
    const partial = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(partial.runs.find((item) => item.runId === "sanitized-live-run")?.health, "partial");
    assert.equal(partial.runs.find((item) => item.runId === "sanitized-live-run")?.queuePosted, 9);
    assert.match(partial.runs.find((item) => item.runId === "sanitized-live-run")?.diagnostic ?? "",
      /2 human-covered finding\(s\) need review/);

    run.overallOutcome = "failure";
    asObject(asObject(run.ownerOperatorOutput).reconciliation).unknown = 0;
    await writeJson(path, run);
    const failed = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(failed.runs.find((item) => item.runId === "sanitized-live-run")?.health, "refused");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("composite coverage delivery results retain class capability identity without changing Owner rows", async () => {
  const fixture = await createFixture();
  try {
    const path = join(fixture.runnerRoot, "last-run.json");
    const run = JSON.parse(await readFile(path, "utf8")) as JsonRecord;
    asObject(run.ownerAutoDelivery).kind = "coverage-v2-automatic-delivery-result";
    await writeJson(path, run);
    const snapshot = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    const coverageRun = snapshot.runs.find((item) => item.runId === "sanitized-live-run");
    assert.equal(coverageRun?.deliveryCapabilityId, "bpm-test-class-coverage@1");
    const coverageRow = reportingRows(snapshot, "runs").find((item) => item.key.startsWith("run:sanitized-live-run:"));
    assert.equal(coverageRow?.capability, "bpm-test-class-coverage@1");
    assert.match(coverageRow?.text.join(" ") ?? "", /Coverage \d+ completed/);
    const ownerRow = reportingRows(snapshot, "runs").find((item) => item.key.startsWith("run:scheduled-"));
    assert.equal(ownerRow?.capability, "owner");

    asObject(run.ownerAutoDelivery).kind = "foreign-automatic-delivery-result";
    await writeJson(path, run);
    const rejected = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(rejected.runs.some((item) => item.runId === "sanitized-live-run"), false);
    assert.ok(rejected.diagnostics.some((item) => /automatic delivery result is unsupported/.test(item)));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("Windows default key verification loads valid feeds and quarantines invalid signatures", {
  skip: process.platform !== "win32",
}, async () => {
  const fixture = await createFixture();
  try {
    const repoRoot = resolve(process.cwd(), "..", "..");
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.roots).toolkit = repoRoot;
    const trustedDelivery = join(fixture.root, "trusted-delivery");
    const trustedManual = join(fixture.root, "trusted-manual");
    const trustBoundary = join(fixture.root, "repository-boundary");
    await copyIntoWindowsTrustedRoot(fixture.deliveryRoot, trustedDelivery, repoRoot, trustBoundary);
    await copyIntoWindowsTrustedRoot(fixture.manualRoot, trustedManual, repoRoot, trustBoundary);
    asObject(config.roots).delivery = trustedDelivery;
    asObject(config.roots).manual = trustedManual;
    asObject(config.budgets).maxScanMilliseconds = 30_000;
    await writeJson(fixture.configPath, config);
    await write(join(trustedDelivery, "events", "invalid-windows.json"), signedEnvelope({
      schemaVersion: 1,
      kind: "owner-v2-delivery-event",
      eventId: "invalid-windows",
      runId: "invalid-windows",
      occurredUtc: "20260924T200200Z",
      runHealth: "healthy",
      subject: {},
      finding: {},
      action: "none",
      outcome: "noOp",
      threadId: null,
      commentId: null,
      url: null,
      modelWriteCount: 0,
      providerWriteCount: 0,
      providerWriteState: "none",
      diagnostic: null,
    }, randomBytes(32)));
    const snapshot = await new LocalReportingAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    const context = JSON.stringify({
      diagnostics: snapshot.diagnostics,
      quarantine: snapshot.quarantine,
      failures: snapshot.failures,
    });
    assert.equal(snapshot.deliveries.some((row) => row.mode === "automatic"), true, context);
    assert.equal(snapshot.deliveries.some((row) => row.mode === "manual"), true, context);
    assert.ok(snapshot.quarantine.some((row) => row.file.endsWith("invalid-windows.json") &&
      /signature verification failed/.test(row.reason)));
    assert.equal(snapshot.diagnostics.some((message) => /permissions are not restrictive/.test(message)), false);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("invalid, truncated, and duplicate automatic events are quarantined and never trusted", async () => {
  const fixture = await createFixture();
  try {
    const eventPath = join(fixture.deliveryRoot, "events", "event-auto-duplicate.json");
    const originalPayload = {
      schemaVersion: 1,
      kind: "owner-v2-delivery-event",
      eventId: "event-auto",
      runId: "run-auto",
      occurredUtc: "20260924T200200Z",
      runHealth: "healthy",
      subject: {
        projectId: "11111111-1111-1111-1111-111111111111",
        repositoryId: "22222222-2222-2222-2222-222222222222",
        pullRequestId: 42,
        sourceCommit: "d".repeat(40),
      },
      finding: {
        stateIdentity: fixture.identity,
        findingId: fixture.findingId,
        marker: fixture.marker,
        path: "tests/Widget Tests.cs",
        line: 12,
        symbol: "<script>alert(1)</script>",
      },
      action: "create",
      outcome: "created",
      threadId: 100,
      commentId: 101,
      url: null,
      modelWriteCount: 0,
      providerWriteCount: 1,
      providerWriteState: "confirmed",
      diagnostic: null,
    };
    await write(eventPath, signedEnvelope(originalPayload, fixture.serviceKey));
    await write(join(fixture.deliveryRoot, "events", "invalid.json"), signedEnvelope({
      ...originalPayload,
      eventId: "invalid",
    }, randomBytes(32)));
    await write(join(fixture.deliveryRoot, "events", "truncated.json"), "{");
    await write(join(fixture.manualRoot, "outcomes", fixture.identity, "invalid-manual.json"), signedEnvelope({
      schemaVersion: 1,
      kind: "owner-v2-comment-outcome",
      invocationId: "invalid-manual",
      stateIdentity: fixture.identity,
      status: "completed",
      providerWrites: 1,
      results: [],
      createdUtc: "20260924T200000Z",
    }, randomBytes(32)));
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    assert.equal(snapshot.deliveries.filter((row) => row.mode === "automatic").length, 0);
    assert.ok(snapshot.quarantine.some((row) => /duplicate delivery eventId/.test(row.reason)));
    assert.ok(snapshot.quarantine.some((row) => /signature verification/.test(row.reason)));
    assert.ok(snapshot.quarantine.some((row) => /manual.*invalid-manual|invalid-manual/i.test(row.file)));
    assert.ok(snapshot.quarantine.some((row) => /JSON/.test(row.reason)));
    assert.equal(snapshot.overall.status, "degraded");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("body derivation fails closed when formatter or digest bindings drift", async () => {
  const fixture = await createFixture();
  try {
    await write(join(fixture.toolkitRoot, "src", "DevPilot.OwnerCapability", "DevPilot.OwnerCapability.psm1"), "drifted formatter\n");
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    const automatic = snapshot.deliveries.find((row) => row.mode === "automatic");
    assert.equal(automatic?.body, null);
    assert.equal(automatic?.bodyStatus, "digest-only");
    assert.match(automatic?.bodySha256 ?? "", /^[0-9a-f]{64}$/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("body derivation never treats independently missing implementation bindings as verified", async () => {
  const fixture = await createFixture();
  try {
    const bodySha256 = sha256Text(fixture.body);
    await write(join(fixture.deliveryRoot, "intents", fixture.identity, "run-auto.json"), signedEnvelope({
      schemaVersion: 1,
      kind: "owner-v2-service-create-intent",
      runId: "run-auto",
      state: { identity: fixture.identity },
      subject: {
        projectId: "11111111-1111-1111-1111-111111111111",
        repositoryId: "22222222-2222-2222-2222-222222222222",
        pullRequestId: 42,
      },
      implementation: {},
      selections: [{
        findingId: fixture.findingId,
        marker: fixture.marker,
        path: "tests/Widget Tests.cs",
        line: 12,
        symbol: "<script>alert(1)</script>",
        body: fixture.body,
        bodySha256,
      }],
      createdUtc: "20260924T200000Z",
    }, fixture.serviceKey));
    const snapshot = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    const automatic = snapshot.deliveries.find((row) => row.mode === "automatic");
    assert.equal(automatic?.body, null);
    assert.equal(automatic?.bodyStatus, "digest-only");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("HMAC keys must pass restrictive permission validation and are never exposed", async () => {
  const fixture = await createFixture();
  try {
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => healthyTask,
      keyPermissionChecker: async () => false,
    }).read();
    assert.equal(snapshot.deliveries.length, 0);
    assert.equal(snapshot.overall.status, "degraded");
    assert.ok(snapshot.diagnostics.some((message) => /permissions are not restrictive/.test(message)));
    assert.doesNotMatch(JSON.stringify(snapshot), new RegExp(fixture.serviceKey.toString("hex"), "i"));
    assert.doesNotMatch(JSON.stringify(snapshot), new RegExp(fixture.manualKey.toString("hex"), "i"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("toolkit drift, task failure, and newer PR heads are surfaced as degraded and stale", async () => {
  const fixture = await createFixture();
  try {
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.expectedToolkit).head = "0".repeat(40);
    await writeJson(fixture.configPath, config);
    await write(join(fixture.deliveryRoot, "events", "event-new-head.json"), signedEnvelope({
      schemaVersion: 1,
      kind: "owner-v2-delivery-event",
      eventId: "event-new-head",
      runId: "run-new-head",
      occurredUtc: "20260924T201000Z",
      runHealth: "refused",
      subject: {
        projectId: "11111111-1111-1111-1111-111111111111",
        repositoryId: "22222222-2222-2222-2222-222222222222",
        pullRequestId: 42,
        sourceCommit: "9".repeat(40),
      },
      finding: {
        stateIdentity: fixture.identity,
        findingId: fixture.findingId,
        marker: fixture.marker,
        path: "tests/Widget Tests.cs",
        line: 12,
        symbol: "<script>alert(1)</script>",
      },
      action: "create",
      outcome: "refused",
      threadId: null,
      commentId: null,
      url: null,
      modelWriteCount: 0,
      providerWriteCount: 0,
      providerWriteState: "none",
      diagnostic: { code: "stale-head", message: "Source head changed." },
    }, fixture.serviceKey));
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => ({ ...healthyTask, lastResult: 1 }),
    }).read();
    assert.equal(snapshot.overall.status, "degraded");
    assert.equal(snapshot.toolkit.matches, false);
    assert.equal(snapshot.findings[0]?.sourceFreshness, "stale");
    assert.ok(snapshot.failures.some((failure) => failure.category === "drift"));
    assert.ok(snapshot.failures.some((failure) => failure.category === "task-failure"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("filters cover time, PR, capability, health/outcome, posting state, and delivery mode", async () => {
  const fixture = await createFixture();
  try {
    const snapshot = await createAdapter(fixture.configPath, {
      now: () => Date.parse("2026-09-24T20:30:00Z"),
      taskReader: async () => healthyTask,
    }).read();
    const filters: ReportingFilters = {
      timeRange: "24h",
      search: "pr:42 capability:ownership outcome:created health:healthy",
      posting: "posted",
      mode: "automatic",
    };
    const filtered = filterReportingRows(reportingRows(snapshot, "deliveries"), filters,
      Date.parse("2026-09-24T20:30:00Z"));
    assert.equal(filtered.length, 1);
    assert.equal(filtered[0]?.mode, "automatic");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("missing/new installation and non-Windows task state stay explicit without failing startup", async () => {
  const root = await mkdtemp(join(process.cwd(), ".reporting-test-empty-"));
  try {
    const state = join(root, "state");
    const toolkit = join(root, "toolkit");
    await mkdir(state, { recursive: true });
    await mkdir(toolkit, { recursive: true });
    const toolkitConfig = join(toolkit, "config.json");
    await writeJson(toolkitConfig, {
      toolkit: { head: "a".repeat(40), tree: "b".repeat(40) },
      autoCreateOwnerComments: false,
    });
    const configPath = join(root, "reporting.json");
    await writeJson(configPath, {
      schemaVersion: 1,
      kind: "devpilot-owner-reporting-config",
      roots: { state, toolkit, config: toolkit },
      files: { toolkitConfig },
      scheduledTaskName: "DevPilot Owner v2",
      refreshIntervalSeconds: 30,
      staleAfterMinutes: 120,
      budgets: { maxFileBytes: 1_048_576, maxFiles: 100, maxHistory: 50, maxScanMilliseconds: 5_000 },
    });
    const snapshot = await createAdapter(configPath, {
      taskReader: async () => ({
        available: false, enabled: null, state: "unsupported",
        lastRunUtc: null, nextRunUtc: null, lastResult: null,
        diagnostic: "Windows Scheduled Tasks are unavailable on this platform.",
      }),
    }).read();
    assert.equal(snapshot.overall.status, "disabled");
    assert.equal(snapshot.findings.length, 0);
    assert.equal(snapshot.deliveries.length, 0);
    assert.equal(snapshot.task.state, "unsupported");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("configured files cannot traverse roots or pass through links/reparse points", async (context) => {
  const fixture = await createFixture();
  try {
    const outside = join(fixture.root, "outside.json");
    await writeJson(outside, { runId: "outside", health: "healthy" });
    const parsed = parseReportingConfiguration(JSON.parse(await readFile(fixture.configPath, "utf8")));
    assert.ok(parsed.roots.runner);
    const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
    asObject(config.files).lastRun = outside;
    await writeJson(fixture.configPath, config);
    const traversed = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.ok(traversed.diagnostics.some((message) => /outside configured roots|expected configured root/.test(message)));

    const linked = join(fixture.runnerRoot, "linked.json");
    try {
      await symlink(outside, linked, "file");
    } catch (error) {
      context.skip(`link creation unavailable: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    asObject(config.files).lastRun = linked;
    await writeJson(fixture.configPath, config);
    const linkedSnapshot = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.ok(linkedSnapshot.diagnostics.some((message) => /link or reparse point/.test(message)));

    const outsideDirectory = join(fixture.root, "outside-events");
    await mkdir(outsideDirectory);
    const eventsDirectory = join(fixture.deliveryRoot, "events");
    await rm(eventsDirectory, { recursive: true, force: true });
    try {
      await symlink(outsideDirectory, eventsDirectory, process.platform === "win32" ? "junction" : "dir");
    } catch (error) {
      context.skip(`directory link creation unavailable: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    asObject(config.files).lastRun = join(fixture.runnerRoot, "last-run.json");
    await writeJson(fixture.configPath, config);
    const linkedDirectorySnapshot = await createAdapter(fixture.configPath, {
      taskReader: async () => healthyTask,
    }).read();
    assert.ok(linkedDirectorySnapshot.diagnostics.some((message) =>
      /events unavailable: .*link or reparse point/.test(message)));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

function asObject(value: unknown): JsonRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as JsonRecord : {};
}

test("scheduled current-head evaluation only credits immutable, independently bound observations", async () => {
  const fixture = await createFixture();
  const intake = syntheticIntake(2);
  const intakeRoot = join(fixture.root, "intake");
  const evaluationRoot = join(fixture.root, "private-evaluation");
  const ledger = join(evaluationRoot, "rule-evaluation-v1");
  const generation = "e".repeat(32);
  asObject(intake.binding).configDigest = "a".repeat(64);
  const intakeHeads = intake.heads as JsonRecord[];
  const first = intakeHeads[0]!;
  first.declaration = {
    repositoryId: asObject(intake.binding).repositoryId,
    projectId: asObject(intake.binding).projectId,
    pullRequestId: first.pullRequestId, sourceRef: "refs/heads/feature",
    targetRef: first.targetRef, sourceCommit: first.sourceCommit,
    targetCommit: first.targetCommit, commonCommit: "b".repeat(40),
    iterationId: first.iterationId, status: "active", isDraft: false,
  };
  first.declarationDigest = sha256Text(JSON.stringify(first.declaration));
  first.lineEvidence = {
    generation: intake.generation, declarationDigest: first.declarationDigest,
    configDigest: asObject(intake.binding).configDigest, baseCommit: "b".repeat(40),
    changedFiles: 1, changedLines: 1, addedLines: 1, deletedLines: 0,
    files: [{ pathDigest: "a".repeat(64), originalPathDigest: null,
      changeType: "edit", addedLines: 1, deletedLines: 0, newLineCount: 1,
      spans: [{ startLine: 1, endLine: 1 }] }],
  };
  first.lineEvidenceDigest = sha256Text(JSON.stringify(first.lineEvidence));
  const ruleDeclaration = {
    schemaVersion: 1, kind: "scheduled-rule-declaration",
    generation, intakeGeneration: intake.generation,
    pullRequestId: first.pullRequestId, sourceCommit: first.sourceCommit,
    targetCommit: first.targetCommit, targetRef: first.targetRef,
    iterationId: first.iterationId, intakeDeclarationDigest: first.declarationDigest,
    lineEvidenceDigest: first.lineEvidenceDigest, configDigest: "c".repeat(64),
    capabilityId: "bpm-future-rule@1", ruleId: "future-rule",
    maxFindingsPerHead: 8, writerEligible: false,
  };
  const declarationBytes = Buffer.from(JSON.stringify(ruleDeclaration));
  const declarationDigest = createHash("sha256").update(declarationBytes).digest("hex");
  const observation = {
    schemaVersion: 1, kind: "scheduled-rule-observation",
    generation, intakeGeneration: intake.generation,
    pullRequestId: first.pullRequestId, sourceCommit: first.sourceCommit,
    targetCommit: first.targetCommit, targetRef: first.targetRef,
    iterationId: first.iterationId, capabilityId: "bpm-future-rule@1",
    ruleId: "future-rule", declarationDigest,
    completedUtc: "2026-09-24T21:00:20Z",
    outcome: { findings: 1, noOp: 0, humanCovered: 0, wouldCreate: 1, unknown: 0 },
    discussionDigest: "d".repeat(64),
    findingOutcomes: [{ findingDigest: "f".repeat(64),
      classification: "wouldCreate", reason: "reviewer-marker-not-found" }],
    providerWrites: 0, modelToolInvocations: 0,
  };
  const observationBytes = Buffer.from(JSON.stringify(observation));
  const digest = createHash("sha256").update(observationBytes).digest("hex");
  const cohort: JsonRecord = {
    schemaVersion: 1, kind: "scheduled-rule-evaluation-cohort",
    generation, intakeGeneration: intake.generation,
    binding: {
      ...asObject(intake.binding), configDigest: "c".repeat(64),
    },
    observedUtc: "2026-09-24T21:01:00Z",
    inventory: { state: "complete", discovered: 2, eligible: 2, excludedOtherTargets: 0,
      draftExcluded: 3 },
    heads: intakeHeads.map((head, index) => ({
      pullRequestId: head.pullRequestId, sourceCommit: head.sourceCommit,
      targetCommit: head.targetCommit, targetRef: head.targetRef,
      iterationId: head.iterationId,
      rules: [{
        capabilityId: "bpm-future-rule@1", ruleId: "future-rule",
        status: index ? "pending" : "evaluated",
        reasonCode: index ? "not-selected" : "completed",
        observationDigest: index ? null : digest,
        declarationDigest: index ? null : observation.declarationDigest,
      }],
    })),
    rules: [{
      capabilityId: "bpm-future-rule@1", ruleId: "future-rule",
      discovered: 2, eligible: 2, evaluated: 1, skipped: 0, unknown: 0,
      error: 0, pending: 1, gaps: [],
    }],
    gaps: [],
  };
  const cohortPath = join(ledger, "cohort.json");
  const immutable = join(ledger, "generations", `${generation}.json`);
  const config = JSON.parse(await readFile(fixture.configPath, "utf8")) as JsonRecord;
  asObject(config.roots).intake = intakeRoot;
  asObject(config.files).intakeCohort = join(intakeRoot, "cohort.json");
  asObject(config.roots).ruleEvaluation = evaluationRoot;
  asObject(config.files).ruleEvaluationCohort = cohortPath;
  await writeJson(fixture.configPath, config);
  await writeJson(join(intakeRoot, "cohort.json"), intake);
  await writeJson(join(intakeRoot, "generations", `${intake.generation}.json`), intake);
  const save = async () => {
    await writeJson(cohortPath, cohort);
    await writeJson(immutable, cohort);
  };
  const read = () => createAdapter(fixture.configPath, {
    now: () => Date.parse("2026-09-24T21:05:00Z"),
    taskReader: async () => healthyTask,
  }).read();
  try {
    const declarationPath = join(ledger, "declarations", `${declarationDigest}.json`);
    await write(declarationPath, declarationBytes);
    await write(join(ledger, "observations", `${digest}.json`), observationBytes);
    await save();
    const valid = await read();
    const rule = valid.rules?.find((entry) => entry.id === "future-rule");
    assert.equal(rule?.scheduled?.evaluated, 1);
    assert.equal(rule?.scheduled?.draftExcluded, 3);
    assert.equal(valid.ruleEvaluation?.draftExcluded, 3);
    assert.notEqual(valid.intake?.binding?.repositoryId, null);
    assert.equal(valid.ruleEvaluation?.binding?.configDigest, "c".repeat(64));
    assert.match(overviewLines(valid).join(" "), /drafts excluded separately 3.*not in the rule denominator/);
    assert.equal(rule?.scheduled?.pending, 1);
    assert.deepEqual(rule?.scheduled?.scope, [1]);
    assert.deepEqual(rule?.scheduled?.findingCounts,
      { findings: 1, noOp: 0, humanCovered: 0, wouldCreate: 1, unknown: 0 });
    assert.equal(rule?.intake?.evaluated, 0);
    assert.equal(rule?.execution, "unknown");
    assert.equal(rule?.counts.finding, null);
    const scheduledRows = reportingRows(valid, "rules").filter((row) => row.key.startsWith("scheduled:"));
    assert.equal(scheduledRows.length, 2);
    assert.match(scheduledRows[0]?.url ?? "", /dev\.azure\.com\/example.*pullrequest\/1/);
    assert.match(scheduledRows[0]?.text.join(" ") ?? "",
      /Findings 1 \| noOp 0 \| humanCovered 0 \| wouldCreate 1 \| unknown 0/);
    assert.match(reportingRows(valid, "rules").find((row) => row.key === "rule:future-rule")?.text.join(" ") ?? "",
      /evaluated 1 \/ pending 1 \/ skipped 0 \/ unknown 0 \/ error 0/);

    const partial = { ...observation,
      outcome: { findings: 1, noOp: 0, humanCovered: 0, wouldCreate: 0, unknown: 1 },
      findingOutcomes: [{ findingDigest: "f".repeat(64),
        classification: "unknown", reason: "discussion-needs-review" }],
    };
    const partialBytes = Buffer.from(JSON.stringify(partial));
    const partialDigest = sha256Text(partialBytes.toString("utf8"));
    await write(join(ledger, "observations", `${partialDigest}.json`), partialBytes);
    asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0]).observationDigest = partialDigest;
    await save();
    const partialView = await read();
    const partialRule = partialView.rules?.find((entry) => entry.id === "future-rule");
    assert.equal(partialRule?.scheduled?.evaluated, 1);
    assert.deepEqual(partialRule?.scheduled?.findingCounts,
      { findings: 1, noOp: 0, humanCovered: 0, wouldCreate: 0, unknown: 1 });
    assert.ok(partialRule?.scheduled?.gaps.includes("discussion-needs-review"));
    asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0]).observationDigest = digest;
    await save();

    await write(declarationPath, "{}");
    const brokenDeclaration = await read();
    assert.equal(brokenDeclaration.rules?.find((entry) => entry.id === "future-rule")?.scheduled?.evaluated, 0);
    assert.equal(brokenDeclaration.rules?.find((entry) => entry.id === "future-rule")?.scheduled?.unknown, 1);
    await write(declarationPath, declarationBytes);
    const mismatchedDeclaration = Buffer.from(JSON.stringify({
      ...ruleDeclaration, lineEvidenceDigest: "b".repeat(64),
    }));
    const mismatchedDeclarationDigest = sha256Text(mismatchedDeclaration.toString("utf8"));
    await write(join(ledger, "declarations", `${mismatchedDeclarationDigest}.json`), mismatchedDeclaration);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).declarationDigest = mismatchedDeclarationDigest;
    await save();
    assert.equal((await read()).rules?.find((entry) => entry.id === "future-rule")?.scheduled?.evaluated, 0);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).declarationDigest = declarationDigest;
    await save();

    await write(join(ledger, "observations", `${digest}.json`), "{}");
    const missingProof = await read();
    assert.equal(missingProof.rules?.find((entry) => entry.id === "future-rule")?.scheduled?.evaluated, 0);
    assert.equal(missingProof.rules?.find((entry) => entry.id === "future-rule")?.scheduled?.unknown, 1);
    assert.match(overviewLines(missingProof).join(" "), /observation-unverified/);

    const driftedBytes = Buffer.from(JSON.stringify({ ...observation, iterationId: 999 }));
    const driftedDigest = createHash("sha256").update(driftedBytes).digest("hex");
    await write(join(ledger, "observations", `${driftedDigest}.json`), driftedBytes);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).observationDigest = driftedDigest;
    await save();
    assert.equal((await read()).rules?.find((entry) => entry.id === "future-rule")?.scheduled?.evaluated, 0);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).observationDigest = digest;
    await save();

    const wrongDeclaration = Buffer.from(JSON.stringify({
      ...observation, declarationDigest: "b".repeat(64),
    }));
    const wrongDeclarationDigest = createHash("sha256").update(wrongDeclaration).digest("hex");
    await write(join(ledger, "observations", `${wrongDeclarationDigest}.json`), wrongDeclaration);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).observationDigest = wrongDeclarationDigest;
    await save();
    assert.equal((await read()).rules?.find((entry) => entry.id === "future-rule")?.scheduled?.evaluated, 0);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).observationDigest = digest;
    await save();

    const missingAuthorization = Buffer.from(JSON.stringify({
      ...observation, providerWrites: undefined,
    }));
    const missingAuthorizationDigest = createHash("sha256").update(missingAuthorization).digest("hex");
    await write(join(ledger, "observations", `${missingAuthorizationDigest}.json`), missingAuthorization);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).observationDigest = missingAuthorizationDigest;
    await save();
    assert.equal((await read()).rules?.find((entry) => entry.id === "future-rule")?.scheduled?.evaluated, 0);
    (asObject((asObject((cohort.heads as JsonRecord[])[0]).rules as JsonRecord[])[0])).observationDigest = digest;
    await save();

    await writeJson(immutable, { ...cohort, observedUtc: "2026-09-24T21:01:01Z" });
    assert.equal((await read()).ruleEvaluation?.state, "unknown");
    const invalidSnapshot = await read();
    assert.equal(invalidSnapshot.rules?.find((entry) => entry.id === "future-rule")?.scheduled, undefined);
    assert.match(reportingRows(invalidSnapshot, "rules")[0]?.text.join(" ") ?? "",
      /SCHEDULED READ-ONLY RULE EVALUATION unknown.*evaluated unknown/);
    await save();
    asObject(cohort.binding).repositoryId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    await save();
    assert.equal((await read()).ruleEvaluation?.state, "unknown");
    asObject(cohort.binding).repositoryId = asObject(intake.binding).repositoryId;
    cohort.intakeGeneration = "a".repeat(32);
    await save();
    assert.equal((await read()).ruleEvaluation?.state, "unknown");
    cohort.intakeGeneration = intake.generation;
    await save();
    asObject(config.files).ruleEvaluationCohort = join(fixture.toolkitRoot, "owner-v2-config.json");
    await writeJson(fixture.configPath, config);
    assert.deepEqual((await read()).ruleEvaluation?.gaps, ["invalid-rule-evaluation-cohort"]);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("scheduled evaluation rejects unsupported totals, duplicate heads, unbound outcomes and config pairs", () => {
  const intakeRaw = syntheticIntake(1);
  asObject(intakeRaw.binding).configDigest = "a".repeat(64);
  const intake = parseIntakeCohort(intakeRaw);
  const head = intake.heads[0]!;
  const raw: JsonRecord = {
    schemaVersion: 1, kind: "scheduled-rule-evaluation-cohort",
    generation: "e".repeat(32), intakeGeneration: intake.generation,
    binding: { ...intake.binding, configDigest: "c".repeat(64) },
    observedUtc: "2026-09-24T21:01:00Z",
    inventory: { state: "complete", discovered: 1, eligible: 1, excludedOtherTargets: 0 },
    heads: [{
      pullRequestId: head.pullRequestId, sourceCommit: head.sourceCommit,
      targetCommit: head.targetCommit, targetRef: head.targetRef, iterationId: head.iterationId,
      rules: [{ capabilityId: "bpm-future-rule@1", ruleId: "future-rule",
        status: "pending", reasonCode: "not-selected", observationDigest: null,
        declarationDigest: null }],
    }],
    rules: [{ capabilityId: "bpm-future-rule@1", ruleId: "future-rule",
      discovered: 1, eligible: 1, evaluated: 0, pending: 1, skipped: 0,
      unknown: 0, error: 0, gaps: [] }],
    gaps: [],
  };
  assert.equal(parseRuleEvaluationCohort(raw, intake).rules[0]?.pending, 1);
  assert.equal(parseRuleEvaluationCohort(raw, intake).draftExcluded, null);
  asObject(raw.inventory).draftExcluded = -1;
  assert.throws(() => parseRuleEvaluationCohort(raw, intake), /invalid rule evaluation count/);
  delete asObject(raw.inventory).draftExcluded;
  asObject((raw.rules as JsonRecord[])[0]).evaluated = 1;
  assert.throws(() => parseRuleEvaluationCohort(raw, intake), /reconcile/);
  asObject((raw.rules as JsonRecord[])[0]).evaluated = 0;
  asObject((raw.heads as JsonRecord[])[0]).sourceCommit = "a".repeat(40);
  assert.throws(() => parseRuleEvaluationCohort(raw, intake), /match intake/);
  asObject((raw.heads as JsonRecord[])[0]).sourceCommit = head.sourceCommit;
  (asObject((raw.heads as JsonRecord[])[0]).rules as JsonRecord[])[0]!.status = "evaluated";
  assert.throws(() => parseRuleEvaluationCohort(raw, intake), /without current-head evidence/);
  const base = {
    schemaVersion: 1, kind: "devpilot-owner-reporting-config",
    roots: { state: resolve("state"), config: resolve("config"), toolkit: resolve("toolkit") },
    files: { toolkitConfig: resolve("toolkit-config.json") },
  };
  assert.throws(() => parseReportingConfiguration({
    ...base, roots: { ...base.roots, ruleEvaluation: resolve("rule-evaluation") },
  }), /configured together/);
  assert.throws(() => parseReportingConfiguration({
    ...base, files: { ...base.files, ruleEvaluationCohort: resolve("cohort.json") },
  }), /configured together/);
});
