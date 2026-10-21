const assert = require("node:assert/strict");

async function requireReleaseEnvironments(github, scope) {
  for (const name of ["release-canary", "release-qualification", "release-publish"]) {
    // Lookup before any job references the name: Actions otherwise creates an unprotected environment.
    const { data: environment } = await github.rest.repos.getEnvironment({
      ...scope, environment_name: name,
    });
    assert.equal(environment.name, name, "Release environment identity mismatch.");
    assert.equal(environment.deployment_branch_policy?.custom_branch_policies, true,
      "Release environment requires an explicit main-only branch policy.");
    assert.equal(environment.deployment_branch_policy?.protected_branches, false,
      "Release environments must select main explicitly, not every protected branch.");
    assert.ok(Array.isArray(environment.protection_rules) &&
      environment.protection_rules.length === 1 &&
      environment.protection_rules[0].type === "branch_policy",
    "Release environment must retain its branch policy without reviewer or custom approvals.");
    const policies = await github.paginate(github.rest.repos.listDeploymentBranchPolicies, {
      ...scope, environment_name: name, per_page: 100,
    });
    assert.ok(policies.length === 1 && policies[0].name === "main" && policies[0].type === "branch",
      "Release environment may admit only the main branch, never tags or wildcards.");
    const { data: custom } = await github.request(
      "GET /repos/{owner}/{repo}/environments/{environment_name}/deployment_protection_rules",
      { ...scope, environment_name: name });
    assert.ok(custom.total_count === 0 &&
      Array.isArray(custom.custom_deployment_protection_rules) &&
      custom.custom_deployment_protection_rules.length === 0,
    "Release environment must not require a custom deployment approval.");
  }
}

async function requireTagProtections(github, scope, line) {
  const summaries = await github.paginate(github.rest.repos.getRepoRulesets, {
    ...scope, includes_parents: false, per_page: 100,
  });
  for (const [name, patterns, types] of [
    ["release-tag-creation", [`refs/tags/v${line}`, `refs/tags/v${line}.*`], ["creation"]],
    [`immutable-v${line}-patches`, [`refs/tags/v${line}.*`], ["update", "deletion"]],
    [`v${line}-channel`, [`refs/tags/v${line}`], ["update", "deletion"]],
  ]) {
    const matches = summaries.filter(rule => rule.name === name);
    assert.equal(matches.length, 1, `Missing or ambiguous protection: ${name}`);
    const { data: rule } = await github.rest.repos.getRepoRuleset({
      ...scope, ruleset_id: matches[0].id, includes_parents: false,
    });
    assert.equal(rule.target, "tag");
    assert.equal(rule.enforcement, "active", `Inactive protection: ${name}`);
    assert.equal(rule.conditions.ref_name.exclude.length, 0, `Excluded tag protection: ${name}`);
    assert.ok(patterns.every(pattern => rule.conditions.ref_name.include.includes(pattern)),
      `Missing version-line pattern: ${name}`);
    assert.ok(types.every(type => rule.rules.some(entry => entry.type === type)),
      `Missing tag restriction: ${name}`);
    // Read tokens may omit actors; the administrator verifies bypass policy during explicit activation.
    if (rule.bypass_actors) {
      assert.ok(name.startsWith("immutable-") ? rule.bypass_actors.length === 0 :
        rule.bypass_actors.every(actor => actor.actor_type === "DeployKey"),
      `Unexpected bypass actor: ${name}`);
    }
  }
}

async function requireMainQualification(github, scope, repository, workflowCommit) {
  const { data: main } = await github.rest.git.getRef({ ...scope, ref: "heads/main" });
  assert.equal(main.object.sha, workflowCommit, "Main advanced; requalify the new commit.");
  const { data: branch } = await github.rest.repos.getBranch({ ...scope, branch: "main" });
  assert.equal(branch.protected, true, "Release qualification requires protected main.");
  const { data: rules } = await github.request(
    "GET /repos/{owner}/{repo}/rules/branches/{branch}", { ...scope, branch: "main" });
  const checks = rules.filter(rule => rule.type === "required_status_checks")
    .flatMap(rule => rule.parameters.required_status_checks);
  assert.ok(rules.some(rule => rule.type === "pull_request") &&
    checks.length > 0 && checks.every(check =>
      typeof check.context === "string" && check.context.length > 0),
  "Release qualification requires main's PR and status-check rules.");
  const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
    ...scope, workflow_id: "ci.yml", head_sha: workflowCommit,
    branch: "main", event: "push", per_page: 100,
  });
  const run = runs.sort((a, b) => b.id - a.id)[0];
  assert.ok(run && Number.isSafeInteger(run.id) && run.id > 0, "No exact-main push CI.");
  assert.equal(run.repository.full_name, repository);
  assert.equal(run.head_repository.full_name, repository);
  assert.equal(run.head_branch, "main");
  assert.equal(run.head_sha, workflowCommit);
  assert.equal(run.path, ".github/workflows/ci.yml");
  assert.equal(run.event, "push");
  assert.equal(run.status, "completed");
  assert.equal(run.conclusion, "success", "Exact-main CI must succeed.");
  const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
    ...scope, run_id: run.id, filter: "latest", per_page: 100,
  });
  assert.ok(jobs.length > 0 && jobs.every(job =>
    job.status === "completed" && job.conclusion === "success"),
  "Every exact-main CI job must succeed without failures, cancellations or skips.");
  assert.ok(checks.every(check => jobs.filter(job => job.name === check.context).length === 1),
    "Exact-main CI must contain every required check exactly once.");
  return run.id;
}

module.exports = async function requireReleasePolicy({
  github, owner, repo, version, workflowCommit, candidateCommit,
  resumePublishedTag = false, resolutionMode = "exactCommit",
}) {
  assert.match(`${owner}/${repo}`, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/);
  assert.match(workflowCommit, /^[0-9a-f]{40}$/);
  assert.match(candidateCommit, /^[0-9a-f]{40}$/);
  assert.match(version, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  assert.ok(version.split(".").map(Number).every(Number.isSafeInteger),
    "Version components exceed safe integers.");
  assert.equal(typeof resumePublishedTag, "boolean");
  assert.ok(["exactCommit", "exactVersion"].includes(resolutionMode));
  if (!resumePublishedTag && resolutionMode === "exactCommit") {
    assert.equal(candidateCommit, workflowCommit, "Fresh release candidate must be exact main.");
  }
  const scope = { owner, repo };
  const line = version.split(".").slice(0, 2).join(".");
  const ciRunId = await requireMainQualification(github, scope, `${owner}/${repo}`, workflowCommit);
  await requireTagProtections(github, scope, line);
  await requireReleaseEnvironments(github, scope);
  // Recovery requalifies the older candidate instead of borrowing current-main source tests.
  return { ciRunId: resumePublishedTag || resolutionMode === "exactVersion" ? null : ciRunId };
};

module.exports.requireTagProtections = requireTagProtections;
module.exports.requireMainQualification = requireMainQualification;
