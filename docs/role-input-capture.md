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
    -OutputRoot ./captures/<name> -SealKeyPath <private-32-byte-key>
```

`-Preflight` performs every readiness check (including requiring an existing
32-byte seal key) and leaves the filesystem
byte-for-byte untouched — no output root, no lease, no plan, no token, no
process. `-VerifyOnly -OutputRoot <bundle>` re-verifies an already published
bundle from scratch using the same `-SealKeyPath`. Capture creates the default
private key under `~/.devpilot` if no key path is supplied; the key is never
stored in the bundle.

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
* reads the production-test-only offline telemetry sink and **fails the capture**
  if it records any child process, model/agency start, provider process, live
  provider write or write-tool invocation.

### Telemetry falsifies; the seal proves

The telemetry sink is deliberately a *falsifier*, not a *verifier*, and the
distinction is worth stating plainly. A no-model capture stops before the model
boundary, so it never opens a provider session and never serves a recorded read
— an **empty sink is the correct outcome**, and this mode must not treat "no
events recorded" as "nothing happened". Absence of evidence is not evidence of
absence, so nothing is inferred from an empty sink.

What telemetry *can* do is disprove the claim: any side-effecting event it
records fails the run outright.

The positive evidence comes from elsewhere:

* `launch.boundaryHits` is exactly `1` in the published manifest, which proves
  the production path really ran all the way to the model boundary and stopped
  there — a capture that never got that far cannot claim it did;
* the manifest is covered by an HMAC seal (`capture-seal.json`) under a key the
  verifier holds independently, so the boundary-hit claim cannot be forged by
  editing the bundle; and
* the interception is the first statement of `Invoke-ReviewerModelSubprocess`,
  so no model process can start regardless of what any counter says.

The capture path launches **no child process of any kind** — not merely no model
processes. Even the running checkout's HEAD is resolved by reading `.git/HEAD`,
symbolic refs, worktree `gitdir` pointers and `packed-refs` directly, rather than
shelling out to `git rev-parse`.

## What a capture publishes

A capture is published atomically — staged in a sibling working directory and
moved into place only once complete — and the published tree is recursively
read-only. It never overwrites: an existing output root is refused.

| File | Contents |
| --- | --- |
| `capture-manifest.json` | the role-scoped capture manifest (schema `role-input-capture.schema.json`) |
| `capture-seal.json` | HMAC-SHA256 authentication of the exact manifest bytes |
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

The seal and all manifest-bound files are assembled in a unique same-volume
sibling staging directory before one atomic rename. No secret, credential,
seal key or oracle value is written. Every side-effect
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

## Known limitations

These are deliberate, and are recorded here rather than hidden.

* **A stale snapshot/build combination is warned about, not refused.** A replay
  snapshot binds the reviewer script hash it was recorded under, and *any* edit
  to the reviewer changes that hash — so refusing on mismatch would make every
  snapshot permanently unusable the moment the agent changed. The existing
  replay behaviour (a warning) is unchanged by this mode. The capture manifest
  records the **running** `configSha256` and `scriptSha256` alongside the
  snapshot's `manifestDigest`, so a consumer can always see which build and
  configuration were combined with which sealed material.
* **Only the generalist reaches the boundary from a purely static projection.**
  The specialist runs the real `Invoke-ReviewerCycle`, and the verifier runs the
  blinded-acquisition verifier entry point; both are existing production
  surfaces rather than capture-only forks, but they need more surrounding sealed
  material (selected packs, a sealed discovery marker) before they reach the
  boundary. Without it they publish a typed `degraded`/`blocked` outcome, which
  is the intended fail-closed behaviour.
* **Telemetry cannot positively corroborate a no-model run.** See
  "Telemetry falsifies; the seal proves" above.
