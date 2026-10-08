---
name: devpilot-release
description: Prepare, publish, resume, or verify a stable DevPilot Agents release on its declared major/minor line. Use when asked to bump the toolkit version, create a release PR, run the release canary, publish a GitHub Release, or confirm release tags.
license: MIT
---

# DevPilot Agents release

Run this skill only from the `joerob-msft/devpilot-agents` repository. Read
`docs/releases.md`, `VERSION`, and the three release workflows before acting.
Those files are authoritative when they differ from this skill.

## Publication boundaries

- A merge to `main` does not publish a release.
- Never create or push release tags directly, run `gh release create`, move
  a channel tag, bypass a ruleset, or approve a protected environment on the
  operator's behalf.
- Publish only through `.github/workflows/release-canary.yml` followed by
  `.github/workflows/release.yml`; `release-auto.yml` may coordinate these
  existing workflows without owning publication or approvals.
- Immutable release tags must never be moved or deleted. The workflows may
  move only the protected floating channel belonging to the requested version.
- The declared line is currently `0.5`. Existing `v0.4` consumers and tag
  protections remain unchanged; publishing `0.5.0` must move only `v0.5`.
- Never print, inspect, copy, or otherwise handle `RELEASE_DEPLOY_KEY`. The
  protected workflow materializes it only inside fixed publication steps.
- Preserve unrelated worktree changes. Stop if they overlap a release metadata
  file or make the candidate ambiguous.

An explicit request to prepare or bump a version authorizes repository edits
and normal pull-request creation. Publishing requires an explicit request to
release or publish the version. Resuming an interrupted publication requires
an explicit request to resume it.

An increasing version-bump merge arms automatic qualification after exact-main
push CI. Human protected-environment approval remains the publication gate.
Ordinary code merges do not arm a release. For an already-merged version,
explicit publication authorization permits dispatching **Release Automation**
from `main`; it passes the bound SHA and successful canary ID internally.
Manual/rollback canaries do not independently authorize automatic publication,
and interrupted releases are never automatically resumed.

## Select the operating mode

Use **prepare** when the requested version is not yet present on `main`. Use
**publish** only when all version metadata is already merged into the exact
current `main`. Use **resume** only when the immutable tag already exists
because an earlier Release run stopped before completing publication.

If the operator requests "the next patch" without naming a version, fetch tags,
find the highest valid stable tag in `release/release-metadata.json`'s declared
version line, and increment its patch component. Do not infer a new major or
minor line. A new line requires explicit operator authorization. Otherwise
require an explicit stable version without the `v` prefix.

## Prepare a release pull request

1. Record `git status --short`, the current branch, the `origin` URL, and the
   latest immutable tag in the requested line. Fetch `origin/main` and tags without changing
   or deleting local work.
2. Refuse a malformed, prerelease, existing, or non-increasing version.
3. Update exactly these version surfaces:
   - `VERSION`
   - `ModuleVersion` in
     `src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1`
   - `version` in `src/DevPilot.Dashboard/package.json`
   - both root package versions in
     `src/DevPilot.Dashboard/package-lock.json`
   - `toolkitVersion`, `versionLine`, `immutableTag`, and `channelTag` in
     `release/release-metadata.json`
4. Keep `versionLine` equal to the version's major/minor, `immutableTag` equal to
   `v<version>`, and `channelTag` equal to `v<major>.<minor>`. For a new line,
   update related workflow contracts, tests, and documentation and require its
   immutable/channel protections before publication. Preserve older line
   protections and bypass actors. Do not create any Git tag.
5. Run:

   ```powershell
   ./tools/Test-DevPilotVersion.ps1 -ExpectedVersion $version `
     -ExpectedTag "v$version"
   ./tools/Invoke-DevPilotCi.ps1 -Mode WindowsComplete
   ```

6. Review the diff and ensure it contains no generated output or unrelated
   changes. Commit only intended release metadata and related line-transition changes and create a pull
   request through the repository's normal protected-branch process.
7. Stop after creating the pull request. Do not merge it or dispatch release
   workflows until the version is present on the exact current `main`.

## Publish a merged version

1. Verify `gh auth status` succeeds and the authenticated repository is
   `joerob-msft/devpilot-agents`.
2. Fetch `origin/main` and tags. Record the full lowercase SHA of
   `origin/main`; call it `$sha`. Require the requested version and every
   version surface to match at that exact commit.
3. Confirm the required `ci.yml` run for `$sha` completed successfully. Do not
   substitute a run for another commit or branch.
   Verify the requested line's active tag protections, preserving older lines
   and bypass actors. After explicit publication authorization, prefer:

   ```powershell
   gh workflow run release-auto.yml --ref main
   ```

   Verify that newly created coordinator is at `$sha`; follow its dispatched
   canary and Release runs and their protected human approvals. It must not
   reuse failed CI, skip a gate, duplicate a pending run, or resume an existing
   immutable tag. The steps below remain the manual coordination path.
4. Snapshot existing Release Canary workflow run IDs, then dispatch:

   ```powershell
   gh workflow run release-canary.yml --ref main `
     -f workflowCommit=$sha `
     -f candidateCommit=$sha `
     -f resolutionMode=exactCommit `
     -f consecutiveRuns=3
   ```

5. Find the newly created run whose head SHA is `$sha` and whose display title
   is `Canary exactCommit - $sha`. Do not guess the run ID or reuse an
   unverified run. Monitor it with `gh run watch <run-id> --exit-status`.
6. Continue only after that exact canary succeeds. Snapshot existing Release
   workflow run IDs, then dispatch:

   ```powershell
   gh workflow run release.yml --ref main `
     -f version=$version `
     -f workflowCommit=$sha `
     -f candidateCommit=$sha `
     -f canaryRunId=$canaryRunId `
     -f resumePublishedTag=false
   ```

7. Find the newly created run titled `Release v$version from $sha` at the exact
   head SHA and monitor it. If a protected environment is waiting for human
   review, report the run URL and wait for the authorized reviewer; never
   bypass or self-approve that gate.
8. After success, fetch tags and verify all of the following:
   - `v$version` is an annotated tag peeled to `$sha`.
   - `gh release view "v$version"` reports a stable, non-draft,
     non-prerelease GitHub Release.
   - The requested version's channel and `v$version^{}` resolve to the same commit.
   - Channels belonging to other version lines have not moved.
9. Report the version, commit, canary run ID, Release run ID, immutable tag,
   GitHub Release URL, and channel verification.

## Resume interrupted publication

Before resuming, prove that `v$version` is an annotated tag at the exact
qualified commit, is the latest stable patch in its declared line, and is the only compatible
patch tag on that commit. Then repeat the publish procedure using the original
successful exact-commit canary and dispatch `release.yml` with
`resumePublishedTag=true`. All qualification and protected environment gates
must run again.

If the immutable tag does not satisfy every resume invariant, stop. Never
repair it manually.

## Failure handling

- Treat any mismatch in repository identity, commit, version metadata, run
  title, run SHA, tag type, release state, or channel target as terminal.
- Do not retry by weakening checks or substituting a newer commit.
- If `main` advances during qualification, let the workflow fail and restart
  publication from the new exact `main` only after deciding whether that new
  commit should be released.
- Rollback is not new-version publication. For an explicit rollback request,
  follow the rollback procedure in `docs/releases.md` and use only
  `release-channel.yml`.
