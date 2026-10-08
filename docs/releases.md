# DevPilot Agents releases

DevPilot Agents publishes immutable patch releases and a protected major/minor
channel. Merging to `main` makes a commit eligible for qualification; it does
not publish that commit. Promotion is the publication boundary.

## Version and reference model

`VERSION` is the authoritative toolkit version. The following files must match
it and are checked by `tools/Test-DevPilotVersion.ps1` in CI and release jobs:

- `src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1`
- `src/DevPilot.Dashboard/package.json`
- the root package entries in `src/DevPilot.Dashboard/package-lock.json`
- `release/release-metadata.json`

A stable `0.5` line has two kinds of Git references:

- `v0.5.0`, `v0.5.1`, and later `v0.5.x` are annotated immutable release tags.
- `v0.5` is an annotated floating channel tag. It may move only to a commit
  that also has exactly one compatible immutable annotated `v0.5.x` tag.

The version line comes from the synchronized release metadata, not a fixed
workflow constant. Publishing `0.5.0` advances only `v0.5`; it never advances
`v0.4` or changes any immutable `v0.4.x` tag. Consumers following `0.4` stay
on that line until they explicitly opt in to `0.5`. The `0.5.0` feature release
adds canonical skill-driven autonomous panels and read-only local Squad memory.

Consumers resolve a channel to a full 40-character commit before installation.
They execute only the verified commit-addressed cache at
`~/.devpilot/toolkits/<commit>`. A mutable tag is never used as an execution
path, an installed cache is never updated in place, and a running dashboard is
never updated.

## Qualification and publication

Ordinary `.github/workflows/ci.yml` remains the required `main` CI. The
dedicated workflows are:

- `release-auto.yml`: default-branch orchestration after successful version-bump
  CI and an automation-started canary; dispatches the existing workflows only.
- `release-canary.yml`: protected live, read-only ADO/WorkIQ qualification.
- `release.yml`: new immutable release publication and its major/minor channel advancement.
- `release-channel.yml`: rollback or repromotion of a version's own channel to an existing
  qualified immutable patch.

### Automatic coordination

Merging an increasing `VERSION` change arms automatic qualification once the
exact-main push CI succeeds. Ordinary code merges do not start a release.
The coordinator reads only protected default-branch code; it rejects PR/fork
events and stale commits, requires every CI job to succeed, and dispatches
`release-canary.yml`. When that automation-started exact-commit canary succeeds,
it passes the verified run ID into `release.yml`.

All existing canary, installed-qualification, and publication environment
approvals remain. The coordinator has Actions write and Contents read only,
does not receive the release deploy key, and cannot create releases or tags.
It uses no PR artifacts or caches and never approves an environment.
An independent manual canary or rollback canary does not authorize automatic
publication.

For an already-merged version or recovery before a tag exists, run **Release
Automation** from `main` once. It selects the current synchronized version and
requires green push CI for that exact commit; no SHA or canary ID is entered.
Existing pending canaries and any prior release attempt are not duplicated.
An existing immutable tag, failed canary, or interrupted release requires the
explicit manual recovery procedures below, never an automatic tag repair or
resume. If `main` advances, qualification must restart for the new commit.

Before approving a new line, configure its creation, immutable, and channel
rulesets. Coordination verifies their active patterns and restrictions before
dispatch; environment approvers also verify bypass actors because read tokens
may not expose them. Automation does not create rulesets or weaken older
lines' protection. Pester container setup/teardown failures fail both CI and
installed qualification even when all individual test assertions passed.

`release.yml` accepts an explicit stable version matching `VERSION`, the exact current
`main` workflow commit, an exact candidate commit, and a successful canary run
ID. Fresh publication requires the workflow and candidate commits to be the
same current `main` commit. It refuses dirty, existing, malformed, prerelease,
or non-monotonic versions. It repeats the complete
Windows and platform-sensitive CI, clones the protected reference consumer,
installs the candidate through the consumer installer into an empty
commit-addressed cache, runs consumer launch-contract tests, and runs the
installed Golden, broker, dashboard, renderer, ConPTY, MCP-recovery, and
agent-DryRun qualification.

Only after all deterministic and live gates succeed does a minimal protected
job materialize the deploy key, create the annotated immutable tag, push it,
and immediately remove the key. A separate read-only qualification job then
resolves that immutable tag through the consumer installer and repeats final
installed smoke tests. A final minimal protected job creates the stable GitHub
Release and moves only that version's major/minor channel last, after rechecking that `main` still names the
qualified workflow commit. No repository-controlled candidate code executes
in a job while a write credential is available.

If interruption occurs after the immutable tag is pushed but before its
GitHub Release is created, rerun the same version and commit with
`resumePublishedTag` enabled. Resume is accepted only when the tag is the
latest stable patch, remains an annotated tag at the exact qualified commit,
and is the sole compatible patch tag on that commit. An existing Release must
be stable. All deterministic, consumer, canary, and final installed gates run
again before the channel can move.

The live canary is **mandatory before advancing any channel**. It performs three to
five consecutive installed-candidate resolutions and fresh authenticated ADO
and WorkIQ MCP sessions on a dedicated self-hosted Windows runner labeled
`devpilot-canary`. Each attempt verifies repository identity, reads the
configured reviewer and review-handler PR snapshots, and reads WorkIQ `/me`.
The script exposes no write operation and does not start a model or dashboard;
those process boundaries are covered by deterministic installed-artifact
qualification. Recoverable transport, generic `-32000` startup, and malformed
startup frames are retried only with entirely fresh ADO and WorkIQ sessions;
repository/PR validation and WorkIQ HTTP failures remain terminal. The runner
must execute as the dedicated operator account with
Agency/Copilot, ADO, and WorkIQ already authenticated. The canary opts its Agency children out of the
`GITHUB_ACTIONS` pipeline-auth marker so they use that desktop identity; the
workflow itself remains a GitHub Actions job. HOME, LOCALAPPDATA, watch state,
durable state, and leases are run-scoped so operator caches and legacy records
cannot affect the result. Agency logging is restricted to errors for the MCP
probe so diagnostic chatter cannot enter the strict JSON-RPC stdout channel.
Never assign this label to pull-request jobs or a shared general-purpose runner.

## Required environments and credentials

Create all three environments before the first release:

- `release-canary`: required reviewers, self-review disabled, deployment branch
  limited to `main`, dedicated self-hosted canary runner, canary PR IDs.
- `release-qualification`: required reviewers, self-review disabled,
  deployment branch limited to `main`, dedicated self-hosted canary runner.
- `release-publish`: required reviewers, self-review disabled, deployment
  branch limited to `main`, and the release deploy key. Publication jobs use
  hosted Windows runners and execute only fixed workflow commands.

Configure these variables and secrets in the environments:

| Name | Kind | Purpose |
|---|---|---|
| `RELEASE_CONSUMER_REPOSITORY_URL` | variable | Protected consumer Git URL |
| `RELEASE_CONSUMER_REF` | variable | Consumer qualification branch |
| `RELEASE_CONSUMER_READ_PAT` | optional secret | Read-only clone credential when the runner has no approved ambient ADO credential |
| `RELEASE_CANARY_REVIEWER_PR` | variable | Stable PR for reviewer read checks |
| `RELEASE_CANARY_HANDLER_PR` | variable | Stable PR for handler read checks |
| `RELEASE_DEPLOY_KEY` | secret | Private half of the repository's dedicated write-enabled release deploy key |

The dedicated runner's ADO credential and any optional PAT must be read-only.
The release deploy key exists only in `release-publish`; its public half is a
write-enabled repository deploy key and it is the only bypass actor on
release-tag creation and channel rulesets. The workflow's `GITHUB_TOKEN`
creates the GitHub Release only after protected-environment approval and final
smoke tests; Git tag writes use the deploy key.

## Required rulesets

Create active repository rulesets with these exact names before enabling the
protected release environments:

1. `main-required-ci`: target `main`; require pull requests, disallow force
   pushes and deletion, require the current CI checks, and require the branch
   to be up to date.
2. `release-tag-creation`: target `v0.4`, `v0.4.*`, `v0.5`, and `v0.5.*`; restrict tag creation;
   the release deploy key is the only bypass actor.
3. `immutable-v0.4-patches`: target `v0.4.*`; restrict updates and deletions;
   configure no bypass actor, including the release deploy key.
4. `v0.4-channel`: target exactly `v0.4`; restrict updates and deletions; the
   release deploy key is the only bypass actor.
5. `immutable-v0.5-patches`: target `v0.5.*`; restrict updates and deletions;
   configure no bypass actor, including the release deploy key.
6. `v0.5-channel`: target exactly `v0.5`; restrict updates and deletions; the
   release deploy key is the only bypass actor.

Keep the `0.4` protections intact. A new version line requires its own immutable
and channel rulesets before publication; a version-file bump alone is not a
release. Never broaden bypass actors when adding that line.

Environment approvers must verify the rulesets in repository settings before
approving the first publication. The required `main` checks are:

- `Generic-toolkit invariant`
- `PSScriptAnalyzer`
- `Module manifest`
- `Targeted Pester tests`
- `Operations dashboard`
- `Agent self-checks (-DryRun)`
- `Platform safety (windows-latest)`
- `Platform safety (ubuntu-latest)`
- `Platform safety (macos-latest)`
- `Dashboard dispatch groundwork (windows-latest)`
- `Dashboard dispatch groundwork (ubuntu-latest)`
- `Dashboard dispatch groundwork (macos-latest)`

Layering the tag rulesets is intentional. The release deploy key can create
patch tags, but the no-bypass immutable ruleset prevents that same identity
from updating or deleting them.

## Release checklist

Repository agents can use
`.github/skills/devpilot-release/SKILL.md` to prepare the version-bump pull
request and dispatch the protected workflows after merge. The skill does not
replace environment approvals, rulesets, or any qualification gate.

1. Update `VERSION`, the harness manifest, dashboard package files, and release
   metadata to the intended stable version (currently `0.5.0`).
2. Run `tools/Test-DevPilotVersion.ps1`.
3. Run `tools/Invoke-DevPilotCi.ps1 -Mode WindowsComplete`.
4. Merge through protected `main` and confirm every required CI check is green
   for the exact commit.
5. Approve the automatic **Release Canary** for a merged version bump, or run
   **Release Automation** once from `main` for an already-merged version.
   It chains the existing protected workflows; approve their required gates.
   For manual coordination, run `Release Canary` with the exact current `main` commit as both
   `workflowCommit` and `candidateCommit`, in `exactCommit` mode. Confirm the
   protected read-only workflow succeeds for at least three consecutive
   launches.
6. For manual coordination, run `Release` with the version, the exact current `main` commit as both
   `workflowCommit` and `candidateCommit`, and the canary run ID.
7. Confirm the immutable annotated tag and stable GitHub Release exist.
8. Confirm the declared channel (currently `v0.5^{}`) and immutable release tag
   resolve to the same qualified commit; confirm `v0.4` was not changed.
9. Start a consumer twice: once online and once with remote access unavailable.
   Both launches must use the receipt's exact commit-addressed cache.

Do not create `v0.5.0` manually. The first release on a new line is published only by
`release.yml` after every gate above succeeds.

## Rollback

Rollback moves only the floating channel; immutable patch tags and GitHub
Releases remain unchanged.

1. Select a prior stable release in the consumers' major/minor line at or above their
   `minimumVersion`.
2. Run `Release Canary` from the exact current `main` `workflowCommit`, in
   `exactVersion` mode, with the prior release commit as `candidateCommit`.
3. Run `Release Channel Promotion` from the exact current `main` workflow
   commit with the target version and successful canary run ID.
4. The workflow re-resolves the annotated immutable tag, verifies the stable
   GitHub Release, installs it into an empty cache, repeats installed smoke
   tests, and then moves only the channel derived from the target version.
5. Verify a fresh consumer resolution records the older qualified patch. An
   offline consumer may continue using its previous receipt until its next
   successful startup check; no running process is changed.

Never delete or move an immutable patch tag to perform rollback. Never move
any channel directly with a local administrator token.

## Trust and failure model

The remote repository identity, explicit pin mode, stable semantic version,
annotated tag object, peeled commit, previously observed immutable tag
bindings, minimum version, and version line are all verified before install.
The consumer builds a new candidate in a staging directory and atomically
publishes the cache only after literal-tree, commit, layout, dashboard, and
launch-contract qualification succeeds. It writes the protected resolution
receipt last.

Network, resolution, installation, build, or verification failure leaves the
prior receipt and cache unchanged. Channel mode warns and launches that
verified last-known-good patch when available. It fails closed when no valid
candidate or matching receipt exists, and it never falls across major/minor
lines or below `minimumVersion`.
