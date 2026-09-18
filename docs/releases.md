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

A stable `0.4` line has two kinds of Git references:

- `v0.4.0`, `v0.4.1`, and later `v0.4.x` are annotated immutable release tags.
- `v0.4` is an annotated floating channel tag. It may move only to a commit
  that also has exactly one compatible immutable annotated `v0.4.x` tag.

Consumers resolve a channel to a full 40-character commit before installation.
They execute only the verified commit-addressed cache at
`~/.devpilot/toolkits/<commit>`. A mutable tag is never used as an execution
path, an installed cache is never updated in place, and a running dashboard is
never updated.

## Qualification and publication

Ordinary `.github/workflows/ci.yml` remains the required `main` CI. The
dedicated workflows are:

- `release-canary.yml`: protected live, read-only ADO/WorkIQ qualification.
- `release.yml`: new immutable patch publication and `v0.4` advancement.
- `release-channel.yml`: rollback or repromotion of `v0.4` to an existing
  qualified immutable patch.

`release.yml` accepts an explicit stable `0.4.x` version, the exact current
`main` workflow commit, an exact candidate commit, and a successful canary run
ID. Fresh publication requires the workflow and candidate commits to be the
same current `main` commit. It refuses dirty, existing, malformed, prerelease,
or non-monotonic versions. It repeats the complete
Windows and platform-sensitive CI, clones the protected reference consumer,
installs the candidate through the consumer installer into an empty
commit-addressed cache, runs consumer launch-contract tests, and runs the
installed Golden, broker, dashboard, renderer, ConPTY, MCP-recovery, and
agent-DryRun qualification.

Only after all deterministic and live gates succeed does the protected publish
job create the annotated immutable tag. It then resolves that immutable tag
through the consumer installer and repeats final installed smoke tests. A
fresh short-lived App token creates the stable GitHub Release and moves `v0.4`
last, after rechecking that `main` still names the qualified commit. A failed,
skipped, or cancelled prerequisite therefore cannot move the channel.

If interruption occurs after the immutable tag is pushed but before its
GitHub Release is created, rerun the same version and commit with
`resumePublishedTag` enabled. Resume is accepted only when the tag is the
latest stable patch, remains an annotated tag at the exact qualified commit,
is the sole compatible patch tag on that commit, and has no GitHub Release.
All deterministic, consumer, canary, and final installed gates run again.

The live canary is **mandatory before advancing `v0.4`**. It runs three to five
consecutive `Start-DevPilot.ps1 -PreviewOnly -Once` launches from the installed
candidate cache. PreviewOnly disables PR, repository, pipeline, work-item,
Teams, and notification writes while still exercising authenticated MCP
startup and representative repository/PR reads. Keep this workflow separate
from pull-request CI because it depends on protected credentials and live
service availability.

## Required environments and credentials

Create both environments before the first release:

- `release-canary`: required reviewers, self-review disabled, deployment branch
  limited to `main`, read-only consumer credential, canary PR IDs.
- `release-qualification`: required reviewers, self-review disabled,
  deployment branch limited to `main`, read-only consumer credential.
- `release-publish`: required reviewers, self-review disabled, deployment
  branch limited to `main`, the same read-only consumer credential, and the
  release GitHub App private key.

Configure these variables and secrets in the environments:

| Name | Kind | Purpose |
|---|---|---|
| `RELEASE_CONSUMER_REPOSITORY_URL` | variable | Protected consumer Git URL |
| `RELEASE_CONSUMER_REF` | variable | Consumer qualification branch |
| `RELEASE_CONSUMER_READ_PAT` | secret | Read-only consumer clone credential |
| `RELEASE_CANARY_REVIEWER_PR` | variable | Stable PR for reviewer read checks |
| `RELEASE_CANARY_HANDLER_PR` | variable | Stable PR for handler read checks |
| `RELEASE_APP_CLIENT_ID` | variable | Release GitHub App client ID |
| `RELEASE_APP_PRIVATE_KEY` | secret | Release GitHub App private key |

The consumer credential must not have write scopes. The GitHub App needs repository Contents write. The rollback workflow also
requests Actions read so it can verify the exact protected canary run. The App
must be the only bypass actor on release-tag creation and channel rulesets.

## Required rulesets

Create active repository rulesets with these exact names before enabling the
protected release environments:

1. `main-required-ci`: target `main`; require pull requests, disallow force
   pushes and deletion, require the current CI checks, and require the branch
   to be up to date.
2. `release-tag-creation`: target `v0.4` and `v0.4.*`; restrict tag creation;
   the release GitHub App is the only bypass actor.
3. `immutable-v0.4-patches`: target `v0.4.*`; restrict updates and deletions;
   configure no bypass actor, including the release App.
4. `v0.4-channel`: target exactly `v0.4`; restrict updates and deletions; the
   release GitHub App is the only bypass actor.

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

Layering the tag rulesets is intentional. The release App can create patch
tags, but the no-bypass immutable ruleset prevents that same identity from
updating or deleting them.

## Release checklist

1. Update `VERSION`, the harness manifest, dashboard package files, and release
   metadata to the intended stable `0.4.x` value.
2. Run `tools/Test-DevPilotVersion.ps1`.
3. Run `tools/Invoke-DevPilotCi.ps1 -Mode WindowsComplete`.
4. Merge through protected `main` and confirm every required CI check is green
   for the exact commit.
5. Run `Release Canary` with the exact current `main` commit as both
   `workflowCommit` and `candidateCommit`, in `exactCommit` mode. Confirm the
   protected read-only workflow succeeds for at least three consecutive
   launches.
6. Run `Release` with the version, the exact current `main` commit as both
   `workflowCommit` and `candidateCommit`, and the canary run ID.
7. Confirm the immutable annotated tag and stable GitHub Release exist.
8. Confirm `v0.4^{}` and `v0.4.x^{}` resolve to the same qualified commit.
9. Start a consumer twice: once online and once with remote access unavailable.
   Both launches must use the receipt's exact commit-addressed cache.

Do not create `v0.4.0` manually. The first release is published only by
`release.yml` after every gate above succeeds.

## Rollback

Rollback moves only the floating channel; immutable patch tags and GitHub
Releases remain unchanged.

1. Select a prior stable `v0.4.x` release at or above the consumers'
   `minimumVersion`.
2. Run `Release Canary` from the exact current `main` `workflowCommit`, in
   `exactVersion` mode, with the prior release commit as `candidateCommit`.
3. Run `Release Channel Promotion` from the exact current `main` workflow
   commit with the target version and successful canary run ID.
4. The workflow re-resolves the annotated immutable tag, verifies the stable
   GitHub Release, installs it into an empty cache, repeats installed smoke
   tests, and then moves `v0.4`.
5. Verify a fresh consumer resolution records the older qualified patch. An
   offline consumer may continue using its previous receipt until its next
   successful startup check; no running process is changed.

Never delete or move an immutable patch tag to perform rollback. Never point
`v0.4` directly with a local administrator token.

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
