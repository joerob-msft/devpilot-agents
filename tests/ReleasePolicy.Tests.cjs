const { test } = require("node:test");
const assert = require("node:assert/strict");
const requirePolicy = require("../.github/scripts/release-policy.cjs");

function fixture() {
  const sha = "a".repeat(40);
  const repository = { full_name: "fixture/toolkit" };
  const ci = {
    id: 42, head_sha: sha, head_branch: "main", event: "push",
    path: ".github/workflows/ci.yml", repository, head_repository: repository,
    status: "completed", conclusion: "success",
  };
  const state = {
    reads: [], main: sha, protected: true,
    rules: [{ type: "pull_request" }, {
      type: "required_status_checks",
      parameters: { required_status_checks: [{ context: "CI" }, { context: "Dashboard" }] },
    }],
    ci: [ci],
    jobs: ["CI", "Dashboard"].map(name => ({ name, status: "completed", conclusion: "success" })),
    environments: ["release-canary", "release-qualification", "release-publish"].map(name => ({
      name, deployment_branch_policy: { custom_branch_policies: true, protected_branches: false },
      protection_rules: [{ type: "branch_policy" }],
    })),
    policies: [{ name: "main", type: "branch" }],
    custom: { total_count: 0, custom_deployment_protection_rules: [] },
    protections: [
      { id: 1, name: "release-tag-creation", types: ["creation"],
        patterns: ["refs/tags/v0.5", "refs/tags/v0.5.*"], bypass_actors: [{ actor_type: "DeployKey" }] },
      { id: 2, name: "immutable-v0.5-patches", types: ["update", "deletion"],
        patterns: ["refs/tags/v0.5.*"], bypass_actors: [] },
      { id: 3, name: "v0.5-channel", types: ["update", "deletion"],
        patterns: ["refs/tags/v0.5"], bypass_actors: [{ actor_type: "DeployKey" }] },
    ],
  };
  const github = {
    paginate: (method, args) => method(args),
    request: async path => ({
      data: path.endsWith("/deployment_protection_rules") ? state.custom : state.rules,
    }),
    rest: {
      git: {
        getRef: async ({ ref }) => {
          state.reads.push(ref);
          assert.equal(ref, "heads/main");
          return { data: { object: { sha: state.main } } };
        },
      },
      repos: {
        getBranch: async () => ({ data: { protected: state.protected } }),
        getEnvironment: async ({ environment_name }) => {
          state.reads.push(environment_name);
          const data = state.environments.find(entry => entry.name === environment_name);
          if (!data) throw Object.assign(new Error("Not found"), { status: 404 });
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
        listWorkflowRuns: async () => state.ci,
        listJobsForWorkflowRun: async args => {
          assert.equal(args.run_id, 42);
          assert.equal(args.filter, "latest");
          return state.jobs;
        },
      },
    },
  };
  return {
    options: {
      github, owner: "fixture", repo: "toolkit", version: "0.5.2",
      workflowCommit: sha, candidateCommit: sha,
    },
    state,
  };
}

test("fresh releases reuse complete exact-main push CI and validate only the existing fixed environments", async () => {
  const { options, state } = fixture();
  assert.deepEqual(await requirePolicy(options), { ciRunId: 42 });
  assert.deepEqual(state.reads, [
    "heads/main", "release-canary", "release-qualification", "release-publish",
  ]);
});

test("resume and rollback validate the trusted current workflow but never reuse its CI for the older candidate", async () => {
  for (const changes of [
    { resumePublishedTag: true },
    { resumePublishedTag: true, candidateCommit: "b".repeat(40) },
    { resolutionMode: "exactVersion", candidateCommit: "b".repeat(40) },
  ]) {
    const { options } = fixture();
    assert.deepEqual(await requirePolicy({ ...options, ...changes }), { ciRunId: null });
  }
});

test("invalid versions, source identities, modes and fresh non-main candidates fail closed", async () => {
  for (const changes of [
    { version: "0.5.2-beta" }, { version: "0.05.2" }, { version: "0.5.9007199254740992" },
    { candidateCommit: "b".repeat(40) }, { workflowCommit: "not-a-sha" },
    { candidateCommit: "" }, { owner: "../other" },
    { resumePublishedTag: "false" }, { resolutionMode: "untrusted" },
  ]) {
    const { options } = fixture();
    await assert.rejects(requirePolicy({ ...options, ...changes }));
  }
});

test("foreign, stale, failed, PR, manual or incomplete CI can never replace exact-main push qualification", async () => {
  for (const mutate of [
    s => { s.main = "b".repeat(40); },
    s => { s.ci = []; },
    s => { s.ci[0].id = "42"; },
    s => { s.ci[0].repository = { full_name: "other/toolkit" }; },
    s => { s.ci[0].head_repository = { full_name: "fork/toolkit" }; },
    s => { s.ci[0].head_sha = "b".repeat(40); },
    s => { s.ci[0].head_branch = "feature"; },
    s => { s.ci[0].event = "pull_request"; },
    s => { s.ci[0].event = "workflow_dispatch"; },
    s => { s.ci[0].path = ".github/workflows/other.yml"; },
    s => { s.ci[0].status = "in_progress"; },
    s => { s.ci[0].conclusion = "failure"; },
    s => { s.ci.push({ ...s.ci[0], id: 43, conclusion: "failure" }); },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    await assert.rejects(requirePolicy(options));
    assert.equal(state.reads.some(value => value.startsWith("release-")), false);
  }
});

test("every CI job must succeed and every required check must be present exactly once", async () => {
  for (const mutate of [
    s => { s.jobs = []; },
    s => { s.jobs.pop(); },
    s => { s.jobs[0].name = "Other check"; },
    s => { s.jobs.push({ ...s.jobs[0] }); },
    s => { s.jobs[0].conclusion = "failure"; },
    s => { s.jobs[0].conclusion = "skipped"; },
    s => { s.jobs[0].conclusion = "cancelled"; },
    s => { s.jobs[0].status = "in_progress"; },
    s => { s.jobs.push({ name: "Optional", status: "completed", conclusion: "skipped" }); },
    s => { s.protected = false; },
    s => { s.rules = s.rules.filter(rule => rule.type !== "pull_request"); },
    s => { s.rules = s.rules.filter(rule => rule.type !== "required_status_checks"); },
    s => { s.rules[1].parameters.required_status_checks = []; },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    await assert.rejects(requirePolicy(options));
  }
});

test("missing, approval-gated, wildcard, protected-branch-wide and tag-admitting environments fail closed", async () => {
  for (const mutate of [
    s => { s.environments.pop(); },
    s => { s.environments[0].name = "other"; },
    s => { s.environments[0].deployment_branch_policy = null; },
    s => { s.environments[0].deployment_branch_policy.protected_branches = true; },
    s => { s.environments[0].protection_rules = []; },
    s => { s.environments[0].protection_rules.push({ type: "required_reviewers" }); },
    s => { s.environments[0].protection_rules.push({ type: "wait_timer" }); },
    s => { s.policies = [{ name: "*", type: "branch" }]; },
    s => { s.policies = [{ name: "main", type: "tag" }]; },
    s => { s.policies.push({ name: "feature/*", type: "branch" }); },
    s => { s.custom = { total_count: 1, custom_deployment_protection_rules: [{ id: 7 }] }; },
    s => { s.custom.total_count = 1; },
  ]) {
    const { options, state } = fixture();
    mutate(state);
    await assert.rejects(requirePolicy(options));
  }
});

test("new lines still require their own active immutable and channel protections", async () => {
  for (const mutate of [
    f => { f.options.version = "0.6.0"; },
    f => { f.state.protections.pop(); },
    f => { f.state.protections[1].types = ["update"]; },
    f => { f.state.protections[1].bypass_actors = [{ actor_type: "DeployKey" }]; },
    f => { f.state.protections[2].bypass_actors = [{ actor_type: "Integration" }]; },
  ]) {
    const f = fixture();
    mutate(f);
    await assert.rejects(requirePolicy(f.options));
  }
});

test("API authorization and transport failures never become a reusable or successful fallback", async () => {
  for (const fail of [
    f => { f.options.github.rest.git.getRef = async () => { throw new Error("Forbidden"); }; },
    f => { f.options.github.rest.actions.listJobsForWorkflowRun = async () => { throw new Error("Forbidden"); }; },
    f => { f.options.github.rest.repos.getEnvironment = async () => { throw new Error("Forbidden"); }; },
    f => {
      const request = f.options.github.request;
      f.options.github.request = async (path, args) => {
        if (path.endsWith("/deployment_protection_rules")) throw new Error("Forbidden");
        return request(path, args);
      };
    },
  ]) {
    const f = fixture();
    fail(f);
    await assert.rejects(requirePolicy(f.options), /Forbidden/);
  }
});
