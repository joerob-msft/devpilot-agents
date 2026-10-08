const { test } = require("node:test");
const assert = require("node:assert/strict");
const coordinate = require("../.github/scripts/release-automation.cjs");

function fixture() {
  const sha = "a".repeat(40);
  const repository = { full_name: "fixture/toolkit" };
  const run = (id, path, event) => ({
    id, path, event, head_sha: sha, head_branch: "main",
    repository, head_repository: repository,
    status: "completed", conclusion: "success",
    actor: { login: "github-actions[bot]" },
  });
  const ci = run(42, ".github/workflows/ci.yml", "push");
  const canary = {
    ...run(50, ".github/workflows/release-canary.yml", "workflow_dispatch"),
    display_title: `Canary exactCommit - ${sha}`,
  };
  const state = {
    ci: [ci], canary: [], releases: [], tag: false,
    refs: [sha], jobs: [{ status: "completed", conclusion: "success" }],
    dispatched: [], messages: [],
    rules: [
      { id: 1, name: "release-tag-creation", rules: [{ type: "creation" }],
        patterns: ["refs/tags/v0.4", "refs/tags/v0.4.*", "refs/tags/v0.5", "refs/tags/v0.5.*"],
        bypass_actors: [{ actor_type: "DeployKey" }] },
      { id: 2, name: "immutable-v0.5-patches", rules: [{ type: "update" }, { type: "deletion" }],
        patterns: ["refs/tags/v0.5.*"], bypass_actors: [] },
      { id: 3, name: "v0.5-channel", rules: [{ type: "update" }, { type: "deletion" }],
        patterns: ["refs/tags/v0.5"], bypass_actors: [{ actor_type: "DeployKey" }] },
    ],
  };
  const missing = () => Object.assign(new Error("Not found"), { status: 404 });
  const github = {
    paginate: (method, args) => method(args),
    rest: {
      repos: {
        getRepoRulesets: async () => state.rules,
        getRepoRuleset: async ({ ruleset_id }) => {
          const rule = state.rules.find(entry => entry.id === ruleset_id);
          return { data: {
            ...rule, target: "tag", enforcement: "active",
            conditions: { ref_name: { include: rule.patterns, exclude: [] } },
          } };
        },
      },
      git: {
        getRef: async ({ ref }) => {
          if (ref === "heads/main") {
            const current = state.refs.length > 1 ? state.refs.shift() : state.refs[0];
            return { data: { object: { sha: current } } };
          }
          if (state.tagError) throw state.tagError;
          if (!state.tag) throw missing();
          return { data: {} };
        },
      },
      actions: {
        getWorkflowRun: async ({ run_id }) => ({
          data: run_id === ci.id ? ci : canary,
        }),
        listWorkflowRuns: async ({ workflow_id }) => ({
          "ci.yml": state.ci,
          "release-canary.yml": state.canary,
          "release.yml": state.releases,
        })[workflow_id],
        listJobsForWorkflowRun: async () => state.jobs,
        createWorkflowDispatch: async args => state.dispatched.push(args),
      },
    },
  };
  const options = {
    github, context: {
      repo: { owner: "fixture", repo: "toolkit" },
      eventName: "workflow_run", ref: "refs/heads/main",
      payload: { workflow_run: { id: ci.id } },
    },
    core: {
      info: message => state.messages.push(message),
      warning: message => state.messages.push(message),
    },
    version: "0.5.0", versionChanged: true, workflowCommit: sha,
  };
  return { options, state, ci, canary, sha };
}

test("a successful version-bump CI starts only the existing protected canary", async () => {
  const { options, state, sha } = fixture();
  assert.equal(await coordinate(options), "canary-dispatched");
  assert.deepEqual(state.dispatched, [{
    owner: "fixture", repo: "toolkit", workflow_id: "release-canary.yml", ref: "main",
    inputs: { workflowCommit: sha, candidateCommit: sha, resolutionMode: "exactCommit", consecutiveRuns: "3" },
  }]);
});

test("ordinary main merges do not arm publication", async () => {
  const { options, state } = fixture();
  options.versionChanged = false;
  assert.equal(await coordinate(options), "no-version-change");
  assert.equal(state.dispatched.length, 0);
});

test("manual automation dispatch can coordinate the already-merged initial version", async () => {
  const { options, state } = fixture();
  options.context.eventName = "workflow_dispatch";
  options.versionChanged = false;
  assert.equal(await coordinate(options), "canary-dispatched");
  assert.equal(state.dispatched.length, 1);
});

test("an automation canary hands its exact successful run to protected Release", async () => {
  const { options, state, canary, sha } = fixture();
  options.context.payload.workflow_run.id = canary.id;
  state.canary.push(canary);
  assert.equal(await coordinate(options), "release-dispatched");
  assert.deepEqual(state.dispatched[0].inputs, {
    version: "0.5.0", workflowCommit: sha, candidateCommit: sha,
    canaryRunId: "50", resumePublishedTag: "false",
  });
  assert.equal(state.dispatched[0].workflow_id, "release.yml");
});

test("manual and rollback canaries cannot grant automatic publication", async () => {
  const { options, state, canary } = fixture();
  options.context.payload.workflow_run.id = canary.id;
  canary.actor.login = "operator";
  assert.equal(await coordinate(options), "manual-canary");
  assert.equal(state.dispatched.length, 0);
  canary.actor.login = "github-actions[bot]";
  canary.display_title = "Canary exactVersion 0.4.0 " + canary.head_sha;
  await assert.rejects(coordinate(options));
});

test("PRs, forks, other branches, failed workflows and malformed IDs cannot dispatch", async () => {
  for (const mutate of [
    f => { f.ci.event = "pull_request"; },
    f => { f.ci.head_repository = { full_name: "fork/toolkit" }; },
    f => { f.ci.repository = { full_name: "other/toolkit" }; },
    f => { f.ci.head_branch = "feature"; },
    f => { f.ci.conclusion = "failure"; },
    f => { f.options.context.payload.workflow_run.id = "42"; },
    f => { f.options.context.eventName = "pull_request_target"; },
  ]) {
    const f = fixture();
    mutate(f);
    await assert.rejects(coordinate(f.options));
    assert.equal(f.state.dispatched.length, 0);
  }
});

test("every exact-main CI job must succeed, without skipped jobs", async () => {
  for (const conclusion of ["failure", "skipped", "canceled", null]) {
    const { options, state } = fixture();
    state.jobs[0].conclusion = conclusion;
    await assert.rejects(coordinate(options), /CI has incomplete/);
    assert.equal(state.dispatched.length, 0);
  }
});

test("newer failed CI cannot be replaced by an older successful event", async () => {
  const { options, state, ci } = fixture();
  state.ci.push({ ...ci, id: 43, conclusion: "failure" });
  await assert.rejects(coordinate(options), /Workflow did not succeed/);
  assert.equal(state.dispatched.length, 0);
});

test("an old canary completion cannot bypass a newer pending attempt", async () => {
  const { options, state, canary } = fixture();
  options.context.payload.workflow_run.id = canary.id;
  state.canary.push(canary, { ...canary, id: 51, status: "waiting", conclusion: null });
  assert.equal(await coordinate(options), "superseded-canary");
  assert.equal(state.dispatched.length, 0);
});

test("main advancing before either dispatch blocks publication", async () => {
  const { options, state, sha } = fixture();
  state.refs = [sha, "b".repeat(40)];
  await assert.rejects(coordinate(options), /Main advanced/);
  assert.equal(state.dispatched.length, 0);
});

test("a pending approved canary is not duplicated", async () => {
  const { options, state, canary } = fixture();
  canary.status = "waiting";
  canary.conclusion = null;
  state.canary.push(canary);
  assert.equal(await coordinate(options), "waiting-canary");
  assert.equal(state.dispatched.length, 0);
});

test("an existing release attempt or immutable tag is never automatically resumed", async () => {
  const { options, state, sha } = fixture();
  state.releases.push({
    head_sha: sha, display_title: `Release v0.5.0 from ${sha}`, conclusion: "failure",
  });
  assert.equal(await coordinate(options), "existing-release-run");
  state.releases = [];
  state.tag = true;
  assert.equal(await coordinate(options), "existing-immutable-tag");
  assert.equal(state.dispatched.length, 0);
});

test("a failed canary and API access failure fail closed instead of retrying", async () => {
  const { options, state, canary } = fixture();
  canary.conclusion = "failure";
  state.canary.push(canary);
  await assert.rejects(coordinate(options), /Workflow did not succeed/);
  state.canary = [];
  state.tagError = Object.assign(new Error("Forbidden"), { status: 403 });
  await assert.rejects(coordinate(options), /Forbidden/);
  assert.equal(state.dispatched.length, 0);
});

test("malformed release version cannot become a tag or dispatch argument", async () => {
  for (const version of ["0.5.0-beta", "0.05.0", "0.5.0; command"]) {
    const { options, state } = fixture();
    options.version = version;
    await assert.rejects(coordinate(options));
    assert.equal(state.dispatched.length, 0);
  }
});

test("a new line without tag protections cannot dispatch a canary", async () => {
  const { options, state } = fixture();
  options.version = "0.6.0";
  await assert.rejects(coordinate(options), /Missing version-line pattern/);
  assert.equal(state.dispatched.length, 0);
});

test("immutable-tag bypass actors cannot be granted by automation", async () => {
  const { options, state } = fixture();
  state.rules[1].bypass_actors = [{ actor_type: "DeployKey" }];
  await assert.rejects(coordinate(options), /Unexpected bypass actor/);
  assert.equal(state.dispatched.length, 0);
});
