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
    -CaptureRequestFile ./bundle/capture-request.json `
    -ConfigFile ./bundle/config/reviewer.config.json `
    -ReplayRoot ./bundle/replay -ReplaySnapshotName <snapshot> `
    -ReplayManifestDigest <64-hex> -PullRequestId <id> `
    -ExpectedHeadCommit <40-hex> -ExpectedRef refs/heads/<branch> `
    -OutputRoot ./captures/<name> -SealKeyPath <private-32-byte-key>
```

The request is intentionally smaller than a PR50 fixture projection. It contains
only fixture/role/model, sealed provider/repository/PR/iteration and
source/common/target/change-set identity, snapshot/config bindings, and
hash-and-length-bound paths inside the snapshot. Its strict schema has no place
for role provenance, prompt/input/script hashes, findings, decisions or expected
results. An optional legacy projection is accepted only as another minimal
identity/resource source and is refused if it already contains role provenance.

The pipeline order is therefore:

1. capture from the independently classified replay plus the minimal request;
2. emit production-derived role provenance and a role-scoped projection;
3. materialize that output with PR50; and
4. run PR49 Preflight over the materialized bundle.

### Feeding the PR50 materializer

Step 3 consumes a legacy `blinded-reviewer-adapter-input` projection together
with the role provenance capture emitted. Supply the legacy identity to capture
with `-LegacyProjectionFile`, and capture re-materializes it with the role
provenance appended into `projections/`; that file is what PR50 takes as
`-LegacyProjectionFile`. Without it a capture still publishes, but it publishes
only the standalone `projection.json`, whose `bindingSha256` is computed over the
capture projection's own binding shape and therefore does not satisfy PR50's
legacy binding check.

This is **not** the PR51 circularity returning. The legacy identity a
materializer-ready capture needs is derivable from the sealed pack alone — the
provider/repository/PR/iteration/commit binding plus the sealed replay manifest
as a hash-and-length-bound resource — and carries no role provenance whatsoever.
Capture is what supplies the role provenance, which is precisely the dependency
that PR51 had backwards. A minimal legacy identity of this shape is built by
`New-CaptureBundle` in `tools/Test-ReviewerRoleInputCapture.ps1`.

Pass `-ReplaySnapshotPath` and `-ExpectedReplayManifestFileSha256` to PR50 as the
**original** sealed pack and its manifest bytes, not the classified copy capture
consumed: the legacy projection seals the original manifest, and PR50 checks the
independent replay manifest against exactly those bytes.

### Separating the captured model from the discovery generalist

`-Model` is the model of the role being captured. For a specialist or verifier
capture the surrounding production run still needs its first generalist model,
which is legitimately a different model — a configuration whose convention
specialist is `claude-sonnet-5` while discovery runs `claude-opus-5` is ordinary.
Pass that first generalist with `-DiscoveryGeneralistModel`; it defaults to
`-Model`, and for a generalist capture it may not differ from `-Model`, because a
generalist capture *is* the discovery generalist. Both models must be among the
models the sealed snapshot was captured for. Without this separation such a
configuration cannot be captured at all: production refuses the pairing before it
ever reaches the boundary.

`-Preflight` performs every readiness check (including requiring an existing
32-byte seal key) and leaves the filesystem
byte-for-byte untouched — no output root, no lease, no plan, no token, no
process. `-VerifyOnly -OutputRoot <bundle>` re-verifies an already published
bundle from scratch using the same `-SealKeyPath`. Capture creates the default
private key under `~/.devpilot` if no key path is supplied; the key is never
stored in the bundle.

The supervisor:

* validates the minimal request against `role-input-capture-request.schema.json`
  and scans the request **and** reviewer configuration recursively for oracle /
  expected-decision keys, and every input path for oracle-ish path segments, so
  an answer key can reach the run neither as data nor as a file name;
* re-resolves `-ExpectedRef` and HEAD from the git object store directly, never
  by running `git`, and fails closed on any disagreement;
* refuses a promotable snapshot, a model the snapshot was not captured for, a
  PR the request is not bound to, a role the request does not declare, and
  a configuration bound to a different repository than the sealed snapshot;
* requires the verifier role to be handed an **independently** captured
  candidate plus the sealed discovery marker it came from, and forbids the other
  roles from carrying either;
* scrubs provider credentials out of the environment the child inherits, so the
  replay code path has no ambient credential to reach for. This is a structural
  guard over *this* code path, not a capability sandbox: it does not remove
  ambient machine credentials such as CLI token caches, credential managers or
  managed identity, and it cannot stop arbitrary outbound HTTP from a PowerShell
  child. What forecloses a live provider read or write is that the capture stops
  at the model boundary and the provider is a sealed replay snapshot; the scrub
  removes the easiest accident on top of that; and
* requires a present, parseable, non-empty production-test-only telemetry sink
  with at least one `provider.replayServed` event **and** a terminal
  `capture.completed` record that covers the published bundle, then **fails the
  capture** if it records any child process, model/agency start, provider
  process, live provider write or write-tool invocation.

### Telemetry must be positive, complete and side-effect-free

Missing or empty telemetry is not proof of zero activity and fails closed. A
successful capture must positively show that production consumed its sealed
snapshot, while recording no model/agency/provider process or live/write event.

State the positive half precisely: `provider.replayServed` is emitted when a read
is dispatched against the sealed corpus rather than after the payload validates,
so the serve count is a count of sealed reads **issued**, not a per-resource
consumption ledger. It is deliberately *not* compared against
`snapshot.resources`: that inventory is the sealed lookup table the replay
provider answers *from*, so a legitimate capture reads only a subset of it and
any inventory-derived floor would be unsound. The serve floor's job is narrower —
it separates a run that genuinely exercised the sealed corpus from an empty,
blank or replay-stripped sink passing off "nothing happened" as "nothing bad
happened".

The serve floor alone does not make the sink *complete*. Telemetry is
append-only JSONL, so a partially written final line fails JSON parse and fails
closed, but a **line-aligned prefix** parses cleanly and could hide a later
`process.started` — which would silently weaken the zero-side-effect claim, the
one guarantee this mode exists to make. The reviewer therefore emits a terminal
`capture.completed` event as the last thing the run writes, bound to the SHA-256
of the document it published, and the supervisor requires that record to be
present, unique, **last**, and bound to the document it just verified. A
truncated prefix loses it, a stale sink from a previous run carries a different
digest, and anything appended afterwards is rejected outright.

The binding is the published document's digest rather than the capture nonce so
that it covers the **blocked** bundle too. A typed blocker is published,
HMAC-sealed and reported with the same zero-side-effect claim as a success, but
it stops before the model boundary and so has no nonce to bind to. Gating the
completeness check on success would have left the prefix-truncation hole open on
exactly the path most likely to have gone wrong, so it applies to *any* published
bundle.

This is a completeness and freshness check, not authentication: it establishes
that the sink covers the whole run that produced *this* bundle. It cannot settle
a child that deliberately forges its own instrumentation, and no
self-instrumentation could. The bundle seal below is what makes the boundary
claim unforgeable.

Two of the side-effect counters are deliberately forward-looking. `process.started`,
`provider.liveProcessStarted`, `provider.liveWrite` and `provider.replayServed`
have live emitters in the harness; the write-tool names the supervisor also
refuses (`tool.write`, `provider.write`, `delivery.posted`) currently have none,
so that particular counter is a reserved guard that will bind the day such an
emitter is added, not present-day evidence. It is listed here rather than left to
imply coverage it does not yet have.

The bundle supplies the complementary boundary evidence:

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

A capture holds a create-new, no-sharing lock for its output name for the entire
run. A concurrent caller is refused before creating work. The winner uses one
GUID for its private same-volume work and staging roots, moves the verified
staging tree into place atomically, and deletes only paths carrying that GUID.
The published tree is recursively read-only and an existing output is never
overwritten.

| File | Contents |
| --- | --- |
| `capture-manifest.json` | the role-scoped capture manifest (schema `role-input-capture.schema.json`) |
| `capture-seal.json` | HMAC-SHA256 authentication of the exact manifest bytes |
| `role-input-prompt.txt` | the exact prompt bytes the model would have received |
| `role-input-request.json` | the role request record the boundary was called with |
| `role-input-marker-schema.json` | the exact result-marker schema for the role |
| `capture-request.json` | the minimal oracle-free identity/resource request |
| `projection.json` | role context derived by production and emitted by capture |
| `sealed-resources/…` | capture-generated model-visible role provenance |

The manifest binds identity (snapshot, PR, repository, project, source / common
/ target commits, change-set digest), role and model, the sealed resource
inventory with a per-resource request and payload digest, the launch deny set,
the non-promotability and build/ref facts, and this hash set:

`inputSha256` (the prompt bytes), `captureRequestSha256`, `requestSha256`, `promptSha256`,
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

`-VerifyOnly` applies the same HMAC/SHA seal, recursive read-only,
reparse-point, and exact unbound-file inventory checks to a typed blocker. Its
success message describes only those checks; it does not infer runtime facts
that are absent from the two-file blocker bundle.

## Prompt equivalence with the blinded adapter path

`tools/Test-ReviewerRoleInputCapture.ps1` captures from a minimal request, emits
role provenance, materializes that output through PR50, and runs PR49 Preflight.
It then runs the blinded acquisition path
(`tools/Invoke-ReviewerBlindedAcquisition.ps1`) over the equivalent fixture with
the offline stub adapter. The only per-attempt difference between the two
stimuli is the nonce the runtime context carries; aligning it and re-hashing
shows the captured prompt bytes equal the adapter's recorded `inputSha256`
exactly. The two paths also agree on the request and prompt-file digests.

All three roles successfully exercise capture -> PR50 materialize -> PR49
Preflight. The suite additionally covers candidate
binding, missing and unsealed sealed material, oracle paths and keys, wrong
identity / model / role / configuration / ref, stimulus substitution, tamper and
smuggled-file detection, blocked-bundle inventory, a simultaneous output-lock
race, read-only publication and `-Preflight` byte-for-byte inertness.

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
* **No role accepts a role projection as input.** Generalist and specialist run
  the real `Invoke-ReviewerCycle`; verifier derives its cluster through the
  production extraction path from an independent marker/candidate, clustering it
  under the **same** `maxCandidates` / `maxClusterSize` / `nearExactJaccard` /
  `semanticJaccard` policy values production passes, and planning its assignment
  set with the production planner (`Get-ReviewerVerificationAssignments`) rather
  than a hand-rolled array — the planner is what decides assignment identity,
  shape, changed-path anchoring, ordering, and the fact that every ready
  candidate is assigned to both configured generalist models, all of which the
  hashed input manifest depends on. The run is then scoped to the
  `(clusterId, verifierModel)` group production would have launched, so a
  multi-finding marker that legitimately derives several clusters is capturable
  without leaking another cluster's evidence into the prompt. Missing sealed
  sources publish a typed `degraded`/`blocked` outcome.
* **Telemetry falsifies and bounds the run; it does not authenticate it.** See
  "Telemetry must be positive, complete and side-effect-free" above.
