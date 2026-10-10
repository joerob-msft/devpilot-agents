const assert = require("node:assert/strict");
const selectReleaseApproval = require("./release-approval.cjs");

module.exports = async function coordinateRelease({
  github, context, core, version, versionChanged, workflowCommit, automaticPatchEnabled = "",
}) {
  const { owner, repo } = context.repo;
  const repository = `${owner}/${repo}`;
  assert.match(repository, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/);
  assert.match(workflowCommit, /^[0-9a-f]{40}$/);
  assert.match(version, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  assert.equal(typeof versionChanged, "boolean");

  function validateRun(run, path, event) {
    assert.ok(Number.isSafeInteger(run.id) && run.id > 0, "Invalid workflow run ID.");
    assert.equal(run.repository.full_name, repository, "Foreign workflow repository.");
    assert.equal(run.head_repository.full_name, repository, "Fork workflow repository.");
    assert.equal(run.head_branch, "main", "Workflow is not on main.");
    assert.equal(run.head_sha, workflowCommit, "Workflow commit is stale.");
    assert.equal(run.path, path, "Unexpected workflow path.");
    assert.equal(run.event, event, "Unexpected workflow event.");
    assert.equal(run.status, "completed", "Workflow has not completed.");
    assert.equal(run.conclusion, "success", "Workflow did not succeed.");
  }

  async function requireCurrentMain() {
    const { data } = await github.rest.git.getRef({ owner, repo, ref: "heads/main" });
    assert.equal(data.object.sha, workflowCommit, "Main advanced; qualify the new commit.");
  }

  async function runs(workflow) {
    return github.paginate(github.rest.actions.listWorkflowRuns, {
      owner, repo, workflow_id: workflow, head_sha: workflowCommit,
      branch: "main", event: "workflow_dispatch", per_page: 100,
    });
  }

  let trigger;
  if (context.eventName === "workflow_run") {
    const id = context.payload.workflow_run.id;
    assert.ok(Number.isSafeInteger(id) && id > 0, "Invalid event run ID.");
    ({ data: trigger } = await github.rest.actions.getWorkflowRun({ owner, repo, run_id: id }));
    if (trigger.path === ".github/workflows/ci.yml") {
      validateRun(trigger, ".github/workflows/ci.yml", "push");
      if (!versionChanged) {
        core.info("No version change in this commit; automatic release is not armed.");
        return "no-version-change";
      }
    } else {
      validateRun(trigger, ".github/workflows/release-canary.yml", "workflow_dispatch");
      assert.equal(trigger.display_title, `Canary exactCommit - ${workflowCommit}`);
      if (trigger.actor.login !== "github-actions[bot]") {
        core.info("Manual canary completion does not authorize automatic publication.");
        return "manual-canary";
      }
    }
  } else if (context.eventName === "schedule") {
    assert.equal(context.ref, "refs/heads/main", "Scheduled coordination must run on main.");
    if (automaticPatchEnabled !== "true" || !versionChanged) {
      return "scheduled-release-disabled";
    }
  } else {
    assert.equal(context.eventName, "workflow_dispatch", "Unsupported automation event.");
    assert.equal(context.ref, "refs/heads/main", "Dispatch automation from main.");
  }

  await requireCurrentMain();
  const ciRuns = await github.paginate(github.rest.actions.listWorkflowRuns, {
    owner, repo, workflow_id: "ci.yml", head_sha: workflowCommit,
    branch: "main", event: "push", per_page: 100,
  });
  const ci = ciRuns.sort((a, b) => b.id - a.id)[0];
  assert.ok(ci, "No exact-main push CI run exists.");
  validateRun(ci, ".github/workflows/ci.yml", "push");
  const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
    owner, repo, run_id: ci.id, filter: "latest", per_page: 100,
  });
  assert.ok(jobs.length > 0 && jobs.every(job =>
    job.status === "completed" && job.conclusion === "success"),
  "CI has incomplete, failed, canceled, or skipped jobs.");

  const line = version.split(".").slice(0, 2).join(".");
  await selectReleaseApproval.requireTagProtections(github, { owner, repo }, line);

  try {
    await github.rest.git.getRef({ owner, repo, ref: `tags/v${version}` });
    core.warning("Immutable tag already exists; automatic publication/resume is refused.");
    return "existing-immutable-tag";
  } catch (error) {
    if (error.status !== 404) throw error;
  }

  const approval = await selectReleaseApproval({
    github, owner, repo, version, workflowCommit, candidateCommit: workflowCommit,
    automaticPatchEnabled,
  });
  if (context.eventName === "schedule" && approval.mode !== "automatic-patch") {
    return "scheduled-manual-release";
  }
  const title = `Release v${version} from ${workflowCommit}`;
  const releases = await runs("release.yml");
  if (releases.some(run => run.head_sha === workflowCommit && run.display_title === title)) {
    core.warning("Release already dispatched; inspect that run rather than automatically retrying.");
    return "existing-release-run";
  }

  const canaryTitle = `Canary exactCommit - ${workflowCommit}`;
  const canaries = (await runs("release-canary.yml"))
    .filter(run => run.head_sha === workflowCommit && run.display_title === canaryTitle)
    .sort((a, b) => b.id - a.id);
  if (trigger?.path === ".github/workflows/release-canary.yml" &&
      canaries[0]?.id !== trigger.id) {
    core.warning("Canary completion was superseded; no release will be dispatched from old evidence.");
    return "superseded-canary";
  }
  const canary = canaries[0];
  if (canary) {
    if (canary.status !== "completed") {
      core.info(`Canary ${canary.id} is still awaiting approval or qualification.`);
      return "waiting-canary";
    }
    validateRun(canary, ".github/workflows/release-canary.yml", "workflow_dispatch");
    if (approval.mode === "automatic-patch") {
      assert.equal(canary.actor.login, "github-actions[bot]",
        "Automatic patch publication requires an automation-started canary.");
    }
    await requireCurrentMain();
    await github.rest.actions.createWorkflowDispatch({
      owner, repo, workflow_id: "release.yml", ref: "main",
      inputs: {
        version, workflowCommit, candidateCommit: workflowCommit,
        canaryRunId: String(canary.id), resumePublishedTag: "false",
      },
    });
    core.info(`Dispatched ${approval.mode} Release ${version} using canary ${canary.id}.`);
    return "release-dispatched";
  }

  await requireCurrentMain();
  await github.rest.actions.createWorkflowDispatch({
    owner, repo, workflow_id: "release-canary.yml", ref: "main",
    inputs: {
      workflowCommit, candidateCommit: workflowCommit,
      resolutionMode: "exactCommit", consecutiveRuns: "3",
    },
  });
  core.info(`Dispatched protected read-only canary for ${workflowCommit}.`);
  return "canary-dispatched";
};
