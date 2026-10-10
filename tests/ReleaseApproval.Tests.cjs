const { test } = require("node:test");
const assert = require("node:assert/strict");
const select = require("../.github/scripts/release-approval.cjs");
const coordinate = require("../.github/scripts/release-automation.cjs");

function fixture() {
  const sha = "a".repeat(40);
  const previous = "b".repeat(40);
  const channelSha = "c".repeat(40);
  const tagSha = "d".repeat(40);
  const ref = (name, objectSha) => ({
    ref: `refs/tags/${name}`, object: { type: "tag", sha: objectSha },
  });
  const repository = { full_name: "fixture/toolkit" };
  const ci = {
    id: 42, head_sha: sha, head_branch: "main", event: "push",
    path: ".github/workflows/ci.yml", repository, head_repository: repository,
    status: "completed", conclusion: "success",
  };
  const canary = {
    ...ci, id: 50, event: "workflow_dispatch",
    path: ".github/workflows/release-canary.yml",
    display_title: `Canary exactCommit - ${sha}`,
    actor: { login: "github-actions[bot]" },
  };
  const state = {
    reads: [], main: sha, protected: true,
    ancestry: { status: "ahead", merge_base_commit: { sha: previous } },
    rules: [{ type: "pull_request" }, {
      type: "required_status_checks",
      parameters: { required_status_checks: [{ context: "CI" }] },
    }],
    channel: ref("v0.5", channelSha), candidate: null,
    tags: [ref("v0.5.1", tagSha)],
    objects: {
      [channelSha]: { sha: channelSha, tag: "v0.5", object: { type: "commit", sha: previous } },
      [tagSha]: { sha: tagSha, tag: "v0.5.1", object: { type: "commit", sha: previous } },
    },
    release: { tag_name: "v0.5.1", draft: false, prerelease: false, published_at: "2026-10-09T00:00:00Z" },
    ci: [ci], jobs: [{ status: "completed", conclusion: "success" }],
    environments: ["release-patch-canary", "release-patch-qualification", "release-patch-publish"]
      .map(name => ({
        name, deployment_branch_policy: { custom_branch_policies: true, protected_branches: false },
        protection_rules: [{ type: "branch_policy" }],
      })),
    policies: [{ name: "main", type: "branch" }],
    canaries: [canary], releases: [], dispatched: [],
    protections: [
      { id: 1, name: "release-tag-creation", types: ["creation"],
        patterns: ["refs/tags/v0.5", "refs/tags/v0.5.*"], bypass_actors: [{ actor_type: "DeployKey" }] },
      { id: 2, name: "immutable-v0.5-patches", types: ["update", "deletion"],
        patterns: ["refs/tags/v0.5.*"], bypass_actors: [] },
      { id: 3, name: "v0.5-channel", types: ["update", "deletion"],
        patterns: ["refs/tags/v0.5"], bypass_actors: [{ actor_type: "DeployKey" }] },
    ],
  };
  const missing = () => Object.assign(new Error("Not found"), { status: 404 });
  const github = {
    paginate: (method, args) => method(args),
    request: async path => ({
      data: path.includes("/compare/") ? state.ancestry : state.rules,
    }),
    rest: {
      git: {
        getRef: async ({ ref }) => {
          state.reads.push(ref);
          if (ref === "heads/main") return { data: { object: { sha: state.main } } };
          const data = ref === "tags/v0.5" ? state.channel : state.candidate;
          if (!data) throw missing();
          return { data };
        },
        getTag: async ({ tag_sha }) => ({ data: state.objects[tag_sha] }),
        listMatchingRefs: async () => state.tags,
      },
      repos: {
        getReleaseByTag: async () => ({ data: state.release }),
        getBranch: async () => ({ data: { protected: state.protected } }),
        getEnvironment: async ({ environment_name }) => {
          state.reads.push(environment_name);
          const data = state.environments.find(entry => entry.name === environment_name);
          if (!data) throw missing();
          return { data };
        },
        listDeploymentBranchPolicies: async () => state.policies,
        getRepoRulesets: async () => state.protections,
        getRepoRuleset: async ({ ruleset_id }) => {
          const rule = state.protections.find(entry => entry.id === ruleset_id);
          return { data: {
            ...rule, target: "tag", enforcement: "active",
            conditions: { ref_name: { include: rule.patterns, exclude: [] } },
            rules: rule.types.map(type => ({ type })),
          } };
        },
      },
      actions: {
        listWorkflowRuns: async ({ workflow_id }) => ({
          "ci.yml": state.ci, "release-canary.yml": state.canaries, "release.yml": state.releases,
        })[workflow_id],
        listJobsForWorkflowRun: async () => state.jobs,
        createWorkflowDispatch: async args => state.dispatched.push(args),
      },
    },
  };
  const options = {
    github, owner: "fixture", repo: "toolkit", version: "0.5.2",
    workflowCommit: sha, candidateCommit: sha, automaticPatchEnabled: "true",
  };
  return { options, state, sha };
}

test("only a qualified published-line patch selects the three fixed automatic environments", async () => {
  const { options } = fixture();
  assert.deepEqual(await select(options), {
    mode: "automatic-patch", canary: "release-patch-canary",
    qualification: "release-patch-qualification", publish: "release-patch-publish",
  });
});

test("default-off, rollback and explicit resume always retain manual approval", async () => {
  for (const changes of [
    { automaticPatchEnabled: "" }, { automaticPatchEnabled: "false" },
    { resumePublishedTag: true }, { resolutionMode: "exactVersion" },
  ]) {
    const { options, state } = fixture();
    const policy = await select({ ...options, ...changes });
    assert.equal(policy.mode, "manual");
    assert.equal(policy.publish, "release-publish");
    assert.equal(state.reads.length, 0);
  }
});

test("a new line and an existing candidate tag never use approval-free environments", async () => {
  for (const mutate of [
    state => { state.channel = null; },
    state => { state.candidate = state.tags[0]; },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    assert.equal((await select(options)).mode, "manual");
    assert.equal(state.reads.filter(value => value.startsWith("release-patch")).length, 0);
  }
});

test("invalid opt-in, version, source and resolution inputs fail closed", async () => {
  for (const changes of [
    { automaticPatchEnabled: "yes" }, { automaticPatchEnabled: true },
    { version: "0.5.2-beta" }, { version: "0.05.2" },
    { candidateCommit: "f".repeat(40) }, { workflowCommit: "not-a-sha" },
    { resumePublishedTag: "false" }, { resolutionMode: "untrusted" },
  ]) {
    const { options } = fixture();
    await assert.rejects(select({ ...options, ...changes }));
  }
});

test("lightweight, forged, ambiguous, rolled-back and non-increasing tag bindings fail closed", async () => {
  for (const mutate of [
    f => { f.state.channel.object.type = "commit"; },
    f => { f.state.objects["d".repeat(40)].object.type = "tag"; },
    f => { f.state.objects["d".repeat(40)].tag = "v0.4.1"; },
    f => { f.state.objects["d".repeat(40)].sha = "e".repeat(40); },
    f => { f.state.objects["d".repeat(40)].object.sha = "e".repeat(40); },
    f => { f.state.tags = []; },
    f => { f.state.tags.push({ ref: "refs/tags/v0.5.1-beta", object: {} }); },
    f => {
      f.state.tags.push({ ref: "refs/tags/v0.5.0", object: { type: "tag", sha: "e".repeat(40) } });
      f.state.objects["e".repeat(40)] = {
        sha: "e".repeat(40), tag: "v0.5.0", object: { type: "commit", sha: "b".repeat(40) },
      };
    },
    f => { f.options.version = "0.5.1"; },
    f => { f.state.main = "e".repeat(40); },
  ]) {
    const f = fixture();
    mutate(f);
    await assert.rejects(select(f.options));
  }
});

test("previous draft, prerelease, unpublished, or foreign Releases cannot qualify a patch", async () => {
  for (const changes of [
    { draft: true }, { prerelease: true }, { published_at: null }, { published_at: "invalid" },
    { tag_name: "v0.4.1" },
  ]) {
    const { options, state } = fixture();
    Object.assign(state.release, changes);
    await assert.rejects(select(options));
  }
});

test("unprotected main, absent PR/check policy, foreign, stale or incomplete CI fails closed", async () => {
  for (const mutate of [
    s => { s.protected = false; }, s => { s.rules = []; },
    s => { s.ci = []; }, s => { s.ci[0].head_sha = "e".repeat(40); },
    s => { s.ci[0].head_repository = { full_name: "fork/toolkit" }; },
    s => { s.ci[0].event = "pull_request"; },
    s => { s.ci[0].conclusion = "failure"; },
    s => { s.ci.push({ ...s.ci[0], id: 43, conclusion: "failure" }); },
    s => { s.jobs = []; }, s => { s.jobs[0].conclusion = "skipped"; },
    s => { s.jobs[0].status = "in_progress"; },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    await assert.rejects(select(options));
  }
});

test("missing, renamed, approval-gated, wildcard or tag-admitting automatic environments fail closed", async () => {
  for (const mutate of [
    s => { s.environments.pop(); }, s => { s.environments[0].name = "other"; },
    s => { s.environments[0].deployment_branch_policy = null; },
    s => { s.environments[0].protection_rules = []; },
    s => { s.environments[0].protection_rules.push({ type: "required_reviewers" }); },
    s => { s.policies = [{ name: "*", type: "branch" }]; },
    s => { s.policies = [{ name: "main", type: "tag" }]; },
    s => { s.policies.push({ name: "feature/*", type: "branch" }); },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    await assert.rejects(select(options));
  }
});

test("API authorization and transport failures never become manual-success fallbacks", async () => {
  for (const method of ["getRef", "getTag"]) {
    const { options } = fixture();
    options.github.rest.git[method] = async () => { throw Object.assign(new Error("Forbidden"), { status: 403 }); };
    await assert.rejects(select(options), /Forbidden/);
  }
  const { options } = fixture();
  options.github.rest.repos.getEnvironment = async () => { throw new Error("Unavailable"); };
  await assert.rejects(select(options), /Unavailable/);
});

test("unrelated candidates and weakened tag protections cannot select automatic environments", async () => {
  for (const mutate of [
    s => { s.ancestry.status = "diverged"; },
    s => { s.ancestry.merge_base_commit.sha = "e".repeat(40); },
    s => { s.protections.pop(); },
    s => { s.protections[1].types = ["update"]; },
    s => { s.protections[1].bypass_actors = [{ actor_type: "DeployKey" }]; },
    s => { s.protections[2].bypass_actors = [{ actor_type: "Integration" }]; },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    await assert.rejects(select(options));
    assert.equal(state.reads.filter(value => value.startsWith("release-patch")).length, 0);
  }
});

test("scheduled continuation hands one successful bot canary to Release without duplicate canaries", async () => {
  const { options, state, sha } = fixture();
  const request = {
    ...options, versionChanged: true, core: { info() {}, warning() {} },
    context: { repo: { owner: options.owner, repo: options.repo }, eventName: "schedule", ref: "refs/heads/main" },
  };
  assert.equal(await coordinate(request), "release-dispatched");
  assert.deepEqual(state.dispatched, [{
    owner: "fixture", repo: "toolkit", workflow_id: "release.yml", ref: "main",
    inputs: { version: "0.5.2", workflowCommit: sha, candidateCommit: sha,
      canaryRunId: "50", resumePublishedTag: "false" },
  }]);
  state.releases.push({ head_sha: sha, display_title: `Release v0.5.2 from ${sha}` });
  assert.equal(await coordinate(request), "existing-release-run");
  assert.equal(state.dispatched.length, 1);
});

test("schedule cannot retry a failed canary, use a manual canary, or arm ordinary merges", async () => {
  for (const mutate of [
    f => { f.state.canaries[0].conclusion = "failure"; },
    f => { f.state.canaries[0].actor.login = "operator"; },
  ]) {
    const f = fixture();
    mutate(f);
    await assert.rejects(coordinate({
      ...f.options, versionChanged: true, core: { info() {}, warning() {} },
      context: { repo: { owner: "fixture", repo: "toolkit" }, eventName: "schedule", ref: "refs/heads/main" },
    }));
    assert.equal(f.state.dispatched.length, 0);
  }
  const { options, state } = fixture();
  assert.equal(await coordinate({
    ...options, versionChanged: false, core: { info() {}, warning() {} },
    context: { repo: { owner: "fixture", repo: "toolkit" }, eventName: "schedule", ref: "refs/heads/main" },
  }), "scheduled-release-disabled");
  assert.equal(state.reads.length, 0);
});
