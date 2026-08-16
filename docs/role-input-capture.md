# No-model production role input capture

`Start-ReviewerAgent.ps1 -CaptureRoleInputRole` runs the **exact current
production** planning, context and prompt construction for **one** role and
**one** model against a permanently non-promotable sealed snapshot, and stops at
the exact production model boundary. It is the answer to a single research
question: *what stimulus would production actually hand this model, byte for
byte?* — answered without ever launching a model.

It is not a review, not an acquisition and not a benchmark run. It authors no
plan file, mints no token, takes no lease, reads nothing live, writes nothing
live, and never promotes anything.

## The boundary

`Invoke-ReviewerModelSubprocess` is the one place the reviewer starts a model.
Capture mode intercepts it as the function's **first statement**: the fully
constructed prompt, runtime context, marker schema and tool grant are recorded
and the call returns before a process object is ever created. "Zero model child
processes" is therefore structural rather than a policy the code promises to
follow.

Everything upstream of that line is untouched production code — the same
builders, the same parser, the same configuration loader and the same model
registry. There is no second prompt implementation to drift.

## Running one

Use the supervisor, which adds the outside half of the guarantee:

```powershell
./tools/Invoke-ReviewerRoleInputCapture.ps1 `
    -Role generalist -Model claude-opus-5 `
    -FixtureProjectionFile ./bundle/projection.json `
    -ConfigFile ./bundle/config/reviewer.config.json `
    -ReplayRoot ./bundle/replay -ReplaySnapshotName <snapshot> `
    -ReplayManifestDigest <64-hex> -PullRequestId <id> `
    -ExpectedHeadCommit <40-hex> -ExpectedRef refs/heads/<branch> `
    -OutputRoot ./captures/<name>
```

`-Preflight` performs every readiness check and leaves the filesystem
byte-for-byte untouched — no output root, no lease, no plan, no token, no
process. `-VerifyOnly -OutputRoot <bundle>` re-verifies an already published
bundle from scratch.

The supervisor:

* validates the projection against `fixture-projection.schema.json` and scans
  the projection **and** the reviewer configuration recursively for oracle /
  expected-decision keys, and every input path for oracle-ish path segments, so
  an answer key can reach the run neither as data nor as a file name;
* re-resolves `-ExpectedRef` and HEAD from the git object store directly, never
  by running `git`, and fails closed on any disagreement;
* refuses a promotable snapshot, a model the snapshot was not captured for, a
  PR the projection is not bound to, a role the projection does not declare, and
  a configuration bound to a different repository than the sealed snapshot;
* requires the verifier role to be handed an **independently** captured
  candidate plus the sealed discovery marker it came from, and forbids the other
  roles from carrying either;
* scrubs provider credentials out of the environment the child inherits, so a
  live read or write is impossible rather than merely unused; and
* proves from the production-test-only offline telemetry sink that zero child
  processes, zero model/agency starts, zero provider processes and zero provider
  writes occurred.

## What a capture publishes

A capture is published atomically — staged in a sibling working directory and
moved into place only once complete — and the published tree is recursively
read-only. It never overwrites: an existing output root is refused.

| File | Contents |
| --- | --- |
| `capture-manifest.json` | the role-scoped capture manifest (schema `role-input-capture.schema.json`) |
| `role-input-prompt.txt` | the exact prompt bytes the model would have received |
| `role-input-request.json` | the role request record the boundary was called with |
| `role-input-marker-schema.json` | the exact result-marker schema for the role |
| `projection.json` | the blinded stimulus projection the capture consumed |
| `sealed-resources/…` | the sealed role provenance the stimulus came from |

The manifest binds identity (snapshot, PR, repository, project, source / common
/ target commits, change-set digest), role and model, the sealed resource
inventory with a per-resource request and payload digest, the launch deny set,
the non-promotability and build/ref facts, and this hash set:

`inputSha256` (the prompt bytes), `requestSha256`, `promptSha256`,
`schemaSha256`, `configSha256`, `scriptSha256`, `snapshotManifestDigest`, and —
for the verifier — `candidateInputSha256`.

No secret, no credential and no oracle value is written. Every side-effect
counter in the manifest is zero, and `launch.boundaryHits` is exactly `1`.

## When it cannot capture

A capture never fabricates and never falls back to anything live. If the sealed
material is missing or the production path legitimately declines to launch the
role, it publishes a **typed blocker** (`capture-blocked.json`, schema
`role-input-capture-blocked.schema.json`) carrying `status` (`blocked` or
`degraded`), a machine-readable `blockedReason`, human detail, and
`boundaryHits: 0`. The supervisor exits `3`. Gates that fail before the capture
driver can publish anything leave no bundle at all.

## Prompt equivalence with the blinded adapter path

`tools/Test-ReviewerRoleInputCapture.ps1` builds a synthetic benchmark pack,
materializes it into a sealed non-promotable snapshot, captures the generalist
role input, and then runs the blinded acquisition path
(`tools/Invoke-ReviewerBlindedAcquisition.ps1`) over the equivalent fixture with
the offline stub adapter. The only per-attempt difference between the two
stimuli is the nonce the runtime context carries; aligning it and re-hashing
shows the captured prompt bytes equal the adapter's recorded `inputSha256`
exactly. The two paths also agree on the request and prompt-file digests.

The suite additionally covers the specialist and verifier roles, candidate
binding, missing and unsealed sealed material, oracle paths and keys, wrong
identity / model / role / configuration / ref, stimulus substitution, tamper and
smuggled-file detection, concurrency, read-only publication and `-Preflight`
byte-for-byte inertness.

## Fixture regeneration

The reviewer script hashes itself into the plans it signs, so any edit to
`src/Agents/reviewer/Start-ReviewerAgent.ps1` invalidates
`tools/testdata/reviewer-acquisition-specialist-projection.json` and
`src/Agents/reviewer/testdata/exact-path/expected-oracle.json`. Regenerate both
as the **last** step before committing, exactly as
`docs/blinded-acquisition.md` describes.
