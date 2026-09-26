import assert from "node:assert/strict";
import test from "node:test";
import { resolveCurrentRelationLink, type RelationReadJson } from "../src/relation-link.js";
import type { RelationSummary, ReportingConfiguration } from "../src/reporting.js";

const source = "c".repeat(40);
const target = "d".repeat(40);
const projectId = "11111111-1111-1111-1111-111111111111";
const repositoryId = "22222222-2222-2222-2222-222222222222";
const config: ReportingConfiguration = {
  schemaVersion: 1, kind: "devpilot-owner-reporting-config",
  roots: { state: "state", toolkit: "toolkit", config: "config" },
  files: { toolkitConfig: "toolkit.json" },
  azureDevOps: {
    organizationUrl: "https://dev.azure.com/example", projectId,
    projectName: "Project Name", repositoryId,
  },
  refreshIntervalSeconds: 30, staleAfterMinutes: 120,
  budgets: { maxFileBytes: 1_048_576, maxFiles: 100, maxHistory: 50, maxScanMilliseconds: 5_000 },
};
const relation: RelationSummary = {
  id: "relation:synthetic", capability: "relation-contextual-review-v1",
  pullRequestId: 42, rule: "synthetic-rule", state: "violation",
  path: "src/NewWidget.cs", line: 193, symbol: "Widget",
  reason: "Historical synthetic assessment", updatedUtc: "2026-09-24T19:00:00Z",
  projectId, repositoryId, sourceCommit: "a".repeat(40), targetCommit: "b".repeat(40),
  targetRef: "refs/heads/master", staleAfterMinutes: 120, writerEligible: false, url: null,
};

function reader(overrides: {
  pr?: Record<string, unknown>;
  iteration?: Record<string, unknown>;
  changes?: Record<string, unknown>;
  item?: Record<string, unknown>;
  secondPr?: Record<string, unknown>;
} = {}): { read: RelationReadJson; calls: URL[] } {
  const calls: URL[] = [];
  let prCalls = 0;
  const pr = {
    pullRequestId: 42, status: "active", isDraft: false,
    repository: { id: repositoryId, project: { id: projectId } },
    targetRefName: "refs/heads/master",
    lastMergeSourceCommit: { commitId: source }, lastMergeTargetCommit: { commitId: target },
    ...overrides.pr,
  };
  const iteration = {
    id: 21, sourceRefCommit: { commitId: source }, targetRefCommit: { commitId: target },
    ...overrides.iteration,
  };
  const read: RelationReadJson = async (url) => {
    calls.push(url);
    if (url.pathname.endsWith("/iterations")) return { value: [iteration] };
    if (url.pathname.endsWith("/changes")) return {
      changeEntries: [{ item: { path: "/src/NewWidget.cs" }, changeType: "edit" }],
      nextSkip: 0, ...overrides.changes,
    };
    if (url.pathname.endsWith("/items")) return {
      path: "/src/NewWidget.cs", gitObjectType: "blob",
      content: Array.from({ length: 200 }, (_, i) => `line ${i + 1}`).join("\n"),
      ...overrides.item,
    };
    if (url.pathname.endsWith("/42")) return ++prCalls === 2 ? { ...pr, ...overrides.secondPr } : pr;
    throw new Error("Unexpected ADO request");
  };
  return { read, calls };
}

test("relation navigation verifies current iteration, changed file and source line, then opens exact deep link", async () => {
  const { read, calls } = reader();
  const url = await resolveCurrentRelationLink(relation, config, read);
  assert.equal(url, "https://dev.azure.com/example/Project%20Name/_git/" +
    `${repositoryId}/pullrequest/42?path=/src/NewWidget.cs&version=GBmaster&line=193` +
    "&lineEnd=194&lineStartColumn=1&lineEndColumn=1&type=2&lineStyle=plain&_a=files&iteration=21&base=0");
  assert.equal(calls.length, 6);
  assert.equal(calls.every((call) => call.hostname === "dev.azure.com" &&
    call.searchParams.get("api-version") === "7.1"), true);
  assert.equal(calls[2]?.searchParams.get("$compareTo"), "0");
  assert.equal(calls[3]?.searchParams.get("versionDescriptor.version"), source);
  assert.equal(calls[3]?.pathname.endsWith(`/${repositoryId}/items`), true);
});

test("relation navigation fails closed on identity, head drift, missing file/line or auth errors", async () => {
  const cases: Array<[string, Parameters<typeof reader>[0]]> = [
    ["PR identity", { pr: { pullRequestId: 43 } }],
    ["PR identity", { pr: { repository: { id: "foreign", project: { id: projectId } } } }],
    ["PR identity", { pr: { repository: { id: repositoryId, project: { id: "foreign" } } } }],
    ["PR identity", { pr: { status: "completed" } }],
    ["PR identity", { pr: { isDraft: true } }],
    ["heads disagree", { iteration: { sourceRefCommit: { commitId: "e".repeat(40) } } }],
    ["heads disagree", { iteration: { targetRefCommit: { commitId: "e".repeat(40) } } }],
    ["heads disagree", { secondPr: { lastMergeSourceCommit: { commitId: "e".repeat(40) } } }],
    ["absent", { changes: { changeEntries: [] } }],
    ["not anchored", { item: { content: "one line" } }],
    ["not anchored", { item: { path: "/other.cs" } }],
  ];
  for (const [diagnostic, overrides] of cases) {
    const { read } = reader(overrides);
    const opened: string[] = [];
    await assert.rejects(async () => {
      opened.push(await resolveCurrentRelationLink(relation, config, read));
    }, new RegExp(diagnostic));
    assert.deepEqual(opened, []);
  }
  await assert.rejects(resolveCurrentRelationLink(relation, config, async () => {
    throw new Error("401 unauthorized");
  }), /401 unauthorized/);
  await assert.rejects(resolveCurrentRelationLink({ ...relation, projectId: "foreign" }, config, reader().read),
    /verified durable PR identity/);
  await assert.rejects(resolveCurrentRelationLink({ ...relation, line: 0 }, config, reader().read),
    /Relation line is invalid/);
  await assert.rejects(resolveCurrentRelationLink({ ...relation, path: "../escape" }, config, reader().read),
    /Relation file path is invalid/);
});
