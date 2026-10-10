const assert = require("node:assert/strict");

const manual = Object.freeze({
  mode: "manual",
  canary: "release-canary",
  qualification: "release-qualification",
  publish: "release-publish",
});
const automatic = Object.freeze({
  mode: "automatic-patch",
  canary: "release-patch-canary",
  qualification: "release-patch-qualification",
  publish: "release-patch-publish",
});

function parseVersion(value) {
  assert.match(value, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  const parts = value.split(".").map(Number);
  assert.ok(parts.every(Number.isSafeInteger), "Version components exceed safe integers.");
  return parts;
}

function compareVersions(left, right) {
  for (let index = 0; index < 3; index++) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

async function getRefOrMissing(github, scope, ref) {
  try {
    return (await github.rest.git.getRef({ ...scope, ref })).data;
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
}

async function peelTag(github, scope, ref, name) {
  assert.equal(ref.ref, `refs/tags/${name}`, "Unexpected tag ref.");
  assert.equal(ref.object.type, "tag", "Release refs must be annotated tags.");
  assert.match(ref.object.sha, /^[0-9a-f]{40}$/);
  const { data: tag } = await github.rest.git.getTag({ ...scope, tag_sha: ref.object.sha });
  assert.equal(tag.sha, ref.object.sha, "Annotated tag identity changed.");
  assert.equal(tag.tag, name, "Annotated tag name mismatch.");
  assert.equal(tag.object.type, "commit", "Release tag must point directly to a commit.");
  assert.match(tag.object.sha, /^[0-9a-f]{40}$/);
  return tag.object.sha;
}

async function requireAutomaticEnvironments(github, scope) {
  for (const name of [automatic.canary, automatic.qualification, automatic.publish]) {
    // Lookup before any job references the name: Actions otherwise creates an unprotected environment.
    const { data: environment } = await github.rest.repos.getEnvironment({
      ...scope, environment_name: name,
    });
    assert.equal(environment.name, name, "Automatic environment identity mismatch.");
    assert.equal(environment.deployment_branch_policy?.custom_branch_policies, true,
      "Automatic environment requires an explicit main-only branch policy.");
    assert.equal(environment.deployment_branch_policy?.protected_branches, false);
    assert.ok(Array.isArray(environment.protection_rules) &&
      environment.protection_rules.length === 1 &&
      environment.protection_rules[0].type === "branch_policy",
    "Automatic environment must retain its branch policy without reviewer or custom approvals.");
    const policies = await github.paginate(github.rest.repos.listDeploymentBranchPolicies, {
      ...scope, environment_name: name, per_page: 100,
    });
    assert.ok(policies.length === 1 && policies[0].name === "main" && policies[0].type === "branch",
      "Automatic environment may admit only the main branch, never tags or wildcards.");
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
  assert.equal(branch.protected, true, "Automatic patches require protected main.");
  const { data: rules } = await github.request(
    "GET /repos/{owner}/{repo}/rules/branches/{branch}", { ...scope, branch: "main" });
  assert.ok(rules.some(rule => rule.type === "pull_request") &&
    rules.some(rule => rule.type === "required_status_checks" &&
      rule.parameters.required_status_checks.length > 0),
  "Automatic patches require main's PR and status-check rules.");
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
  "Every exact-main CI job must succeed.");
}

module.exports = async function selectReleaseApproval({
  github, owner, repo, version, workflowCommit, candidateCommit,
  automaticPatchEnabled = "", resumePublishedTag = false, resolutionMode = "exactCommit",
}) {
  assert.match(`${owner}/${repo}`, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/);
  assert.match(workflowCommit, /^[0-9a-f]{40}$/);
  assert.match(candidateCommit, /^[0-9a-f]{40}$/);
  const candidate = parseVersion(version);
  assert.ok(["", "false", "true"].includes(automaticPatchEnabled),
    "DEVPILOT_AUTOMATIC_PATCH_RELEASES must be empty, false or true.");
  assert.equal(typeof resumePublishedTag, "boolean");
  assert.ok(["exactCommit", "exactVersion"].includes(resolutionMode));
  if (automaticPatchEnabled !== "true" || resumePublishedTag || resolutionMode !== "exactCommit") {
    return { ...manual };
  }
  assert.equal(candidateCommit, workflowCommit, "Automatic patch candidate must be exact main.");
  const scope = { owner, repo };
  const line = candidate.slice(0, 2).join(".");
  const candidateTag = `v${version}`;
  const existingCandidate = await getRefOrMissing(github, scope, `tags/${candidateTag}`);
  if (existingCandidate) return { ...manual }; // Partial publication requires explicit recovery.
  const channel = await getRefOrMissing(github, scope, `tags/v${line}`);
  if (!channel) return { ...manual }; // A new line always retains human approval.

  const channelCommit = await peelTag(github, scope, channel, `v${line}`);
  const refs = await github.paginate(github.rest.git.listMatchingRefs, {
    ...scope, ref: `tags/v${line}.`, per_page: 100,
  });
  const tagPattern = new RegExp(`^refs/tags/v${line.replace(".", "\\.")}\\.(0|[1-9][0-9]*)$`);
  const versions = [];
  for (const ref of refs) {
    assert.match(ref.ref, tagPattern, "Malformed or prerelease ref in immutable namespace.");
    const tag = ref.ref.slice("refs/tags/".length);
    versions.push({
      tag, version: parseVersion(tag.slice(1)),
      commit: await peelTag(github, scope, ref, tag),
    });
  }
  assert.ok(versions.length > 0, "Channel has no immutable patch binding.");
  versions.sort((a, b) => compareVersions(b.version, a.version));
  const latest = versions[0];
  assert.equal(latest.commit, channelCommit,
    "Channel must name the highest existing patch; rollback or partial publication stays manual.");
  assert.equal(versions.filter(entry => entry.commit === channelCommit).length, 1,
    "Channel must have exactly one compatible immutable binding.");
  assert.notEqual(channelCommit, candidateCommit, "Candidate already carries a release.");
  assert.ok(compareVersions(candidate, latest.version) > 0, "Automatic patch must strictly increase.");
  const { data: release } = await github.rest.repos.getReleaseByTag({
    ...scope, tag: latest.tag,
  });
  assert.equal(release.tag_name, latest.tag);
  assert.equal(release.draft, false);
  assert.equal(release.prerelease, false);
  assert.ok(typeof release.published_at === "string" && Number.isFinite(Date.parse(release.published_at)),
    "Previous patch must be a published stable Release.");
  const { data: ancestry } = await github.request(
    "GET /repos/{owner}/{repo}/compare/{basehead}", {
      ...scope, basehead: `${channelCommit}...${candidateCommit}`,
    });
  assert.equal(ancestry.status, "ahead", "Candidate must descend from the published predecessor.");
  assert.equal(ancestry.merge_base_commit.sha, channelCommit, "Published predecessor is not an ancestor.");
  await requireMainQualification(github, scope, `${owner}/${repo}`, workflowCommit);
  await requireTagProtections(github, scope, line);
  await requireAutomaticEnvironments(github, scope);
  return { ...automatic };
};

module.exports.requireTagProtections = requireTagProtections;
