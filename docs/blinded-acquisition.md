# Blinded transcript acquisition

This runner captures **exactly one** blinded model transcript for one declared
reviewer role against a sealed, non-promotable replay snapshot. It establishes a
**raw orchestration stimulus, not model quality and not decision correctness**.
It exercises the production prompt construction, result-marker parser, schemas,
scan windows, retry classification, sealed routing and model subprocess
boundary, and seals whatever the model emitted. It does not judge whether that
emission is right, useful, safe, or deliverable.

Acquisition is deliberately blind: it never loads, accepts, derives, or consults
an oracle or an expected decision. Correctness adjudication is a separate,
later, evidence-sealed step that a human authorizes against an independently
authored oracle; nothing here may be presented as that step.

## What it guarantees

* **Oracle-free by construction.** The projection and candidate inputs are
  validated by a strict JSON schema **and** a recursive forbidden-key scan.
  Any `expected*`/`oracle*`/`decision`/`groundTruth`/`label` field, at any
  depth, fails the run closed before a model is ever addressed.
* **Exactly one role/model invocation.** One authorized declaration launches one
  role against one model. The only repetition permitted is each role's existing
  bounded fresh-nonce retry for a *retryable* result-marker emission failure
  (missing or truncated marker, stdout saturation): the generalist reuses the
  reviewer's generalist retry budget and the specialist reuses its own
  convention-specialist budget. A terminal schema/binding failure never retries;
  the verifier's cross-verification pass is always terminal by policy.
* **No resume, no replacement, no automatic next role.** Launch is guarded by an
  atomic `CreateNew` parent-sidecar lease keyed by the canonical output-root path.
  It is the tool's **first** mutation, taken before the output root, plan, or any
  work directory is created. A losing concurrent caller creates nothing beneath
  the requested root. A consumed lease cannot be reused; a fresh role needs a new
  separately named output root and authorized plan.
* **Token never travels in argv, and the plan is HMAC-signed and verified
  constant-time inside the gate.** The supervisor hands the raw authorization
  token to the child only through a scrubbed environment variable (never a
  command-line argument, never persisted). It also **HMAC-signs the canonical
  plan bytes** with a key derived from that token (SHA-256 of the token) and
  writes the tag to a `.sig` sidecar. The reviewer's acquisition gate reads the
  token, removes it from the environment, constant-time compares its SHA-256 to
  the plan's `authorizationTokenSha256`, and re-derives the same key to
  constant-time verify the plan signature over the exact plan bytes. Because the
  signature covers the whole plan — repoPath, outputRoot, config, model, ref,
  head, role and every bound identity — a tampered, replayed, or wrong-root plan,
  a missing token (a direct bypass of the supervisor), or a mismatch all fail
  closed with no model launched.
* **The child independently re-resolves and binds HEAD and the full ref.** The
  gate runs its own `git -C <RepoPath> rev-parse` for HEAD and for
  `expectedRef^{commit}` and **fails closed** on any non-zero or empty result —
  it never silently skips the identity — then requires both to equal the plan's
  bound `expectedHeadCommit`. A non-git RepoPath, a detached or moved HEAD, or a
  valid-but-wrong ref is refused before launch.
* **The fixture/replay target identity is canonical and cross-checked.** The
  supervisor authors a single canonical target — PR id, repository, project,
  source commit, target commit, and change-set digest into the signed plan, and
  cross-checks it against the projection
  binding. The child re-validates that `plan.target` exactly equals the sealed
  replay snapshot's own bound identity before any role launches, so a projection
  or plan whose source commit, target commit or change-set digest disagrees with
  the sealed snapshot is refused with no model launched.
* **The offline adapter is contained, never injected.** Deterministic test runs
  require the explicit `-UseOfflineStubAdapter` switch; the reviewer then pins
  execution to the repository's sealed offline stub adapter, checked by both
  expected file hash and path containment. The adapter manifest may select a stub
  *behavior* but can never swap the pinned script or executable. One credential
  regression reaches the production subprocess boundary through a local
  pwsh-backed fake that exits before any model or tool can run; no real model
  executable or provider is launched.
* **No provider access or write.** Replay is permanently preview-only with no
  live fallback. Repository, provider, comment, vote, work-item and delivery
  paths are refused. Azure DevOps/write-provider credentials are scrubbed from
  the reviewer and Copilot path. Copilot's GitHub authentication credential is
  preserved along that path through the Copilot subprocess boundary; every
  MCP/tool child is scrubbed of both Azure DevOps and GitHub credentials. Direct
  telemetry proves that zero provider processes and zero live writes occurred. Production
  launches the one authorized model; deterministic tests use the pinned stub
  and additionally prove zero real-model starts.
* **Immutable, credential-free seal.** The package captures raw stdout/stderr,
  the parsed result marker, the reported model, role, fresh nonce and its hash,
  the request/input/prompt/schema/config/script/snapshot/candidate digests, the
  attempt ledger (each attempt's exact production parser/run classification —
  status, typed reason, retryability, whether the model ran, usage and the
  attempt nonce hash), timestamps/durations, the terminal status and zero-write
  telemetry. It **never** persists the authorization token or any credential —
  only the token's SHA-256. A canonical manifest recursively inventories every
  package file **and directory**, rejects any unexpected nested file or
  directory, any empty directory, and any reparse-point (symlink/junction) file
  or directory, and binds each file's byte length and SHA-256 plus the pack and
  snapshot identity. The whole tree is marked read-only — the seal fails closed
  if any read-only attribute cannot be set — and the manifest itself is sealed
  with an HMAC (authenticated) tag, so a tamper, a missing file, or a
  substitution of an individually valid file from a separate package is all
  detected on re-verify.
* **The captured model equals the authorized plan model.** The gate selects the
  authorized `plan.model` assignment before launch and fails closed if no
  assignment names it; the launched and reported model must equal `plan.model`,
  so a cross-model substitution (including across supported families) is refused.
* **Authenticated terminal evidence.** A timeout (exit 124) or crash still seals
  immutable, read-only terminal evidence — including the supervisor's own direct
  stdout/stderr logs — under the same HMAC seal and the same recursive inventory,
  so the abnormal outcome is itself tamper-evident.

## Two-layer architecture

The exact production path must *execute*, not be re-implemented. So the runner is
split in two, and all prompt/parser/subprocess logic lives only in the reviewer:

* **Outer supervisor** — `tools/Invoke-ReviewerBlindedAcquisition.ps1`.
  Validates every input (strict schema + recursive forbidden-key scan), resolves
  and validates the model through the module registry, runs the exact current
  build/clean/ref/ancestor checks, authors and schema-validates a single
  authorized acquisition plan, holds the atomic launch lease, scrubs
  write-provider credentials while retaining Copilot's GitHub authentication,
  supervises the reviewer child with direct stdout/stderr files,
  per-call and total deadlines, an activity watchdog, a bounded drain, recursive
  owned-tree cancellation and exit code 124 on timeout, then seals the package
  and verifies zero-write telemetry. It identifies the child by PID/handle, never
  by command-text matching.

* **Inner gated mode** — `Start-ReviewerAgent.ps1` under its
  `-AcquireTranscriptRole` acquisition gate. This is the production reviewer
  running its exact prompt construction, result-marker parser, schemas, scan
  windows, retry classification/accounting, sealed routing and model subprocess
  boundary. Before any launch the gate independently verifies the plan's token
  SHA-256 and HMAC signature, re-resolves and binds HEAD and the full ref
  (failing closed on any git failure), and consumes a one-shot lease. A capture
  hook at the subprocess boundary records each attempt's raw stimulus and its
  exact production parser/run classification. When the gate is inactive the hook
  is a strict no-op and emits nothing, so ordinary orchestration is unchanged.

Because the reviewer binds a hash of its own file into its sealed plan and
marker provenance, editing the reviewer legitimately changes the exact-path
semantic golden. That golden is regenerated on production script changes; the
change is proven to be only the self-hash, never an orchestration change.

## Inputs

| Input | Constraint |
| --- | --- |
| Role | exactly one of `generalist` \| `specialist` \| `verifier` |
| Fixture projection | one blinded projection JSON, strict schema + forbidden-key scan |
| Discovery candidate | verifier only; independently captured, exact source/fixture/model/result-marker binding |
| Discovery package | verifier only; the SEALED discovery transcript package the candidate was extracted from |
| Cross-check models | every role binds the current distinct generalist pair plus whether the convention specialist is enabled and its effective model; specialist/verifier always enable it, while generalist follows verification config or an explicit override |
| Model | one supported id, validated through `Assert-AgentSupportedModel` |
| Replay snapshot | one digest-bound, non-promotable sealed snapshot |
| Expected commit / ref / RepoPath | exact HEAD, full `refs/heads/<branch>` resolving to that HEAD, and repository path |
| Output root | where the sealed package is written |
| Authorization token | cryptographically random; only its SHA-256 is persisted |

## Materializing legacy blinded benchmark packs

`tools/Convert-ReviewerBlindedBenchmarkPack.ps1` converts the legacy
`blinded-reviewer-adapter-input` shape into a role-scoped
`reviewer-blinded-fixture-projection` and a production-loadable acquisition
bundle. It does not infer role context from fixture names or reconstruct replay,
config, or prompt content.

The conversion requires:

* exactly one replay manifest already sealed by the legacy projection;
* one exact `reviewer-model-visible-role-provenance` resource already sealed by
  that projection with media role `role-provenance-<role>`;
* an independently supplied replay snapshot whose manifest bytes equal the
  sealed manifest;
* independently supplied config and prompt bytes pinned by operator SHA-256
  (and by the replay manifest whenever it records nonzero bindings).

Every declared resource is schema-, path-, SHA-256-, and length-checked.
Legacy replay manifests with an empty `bindings.models` list are intentionally
out of scope: materialization requires the replay to bind the configured
generalist paired with `-SecondGeneralistModel`.
Oracle/expected fields and oracle-bearing or aliased paths are rejected
recursively. The output is staged, accepted by `New-AgentReplaySnapshot`, fully
inventoried in `transformation-manifest.json`, marked read-only, and atomically
renamed into place. Missing or ambiguous provenance blocks conversion; the tool
never fills gaps from a live repository or a human-authored guess.

The classified replay sidecar binds the exact config, production prompt, and
reviewer script hashes. Acquisition rechecks those bindings against the running
bytes. The materializer also requires and binds the current second generalist. When
the role or verification config requires the convention specialist, it binds
that enablement and effective model too. `-ConventionSpecialistModel` takes
precedence over `config.review.conventionSpecialistModel`; both models extend
the classified replay's model binding. Specialist acquisition additionally requires both sealed convention and
fact plans and compares them to the production-generated plans before the model
boundary; a merely role-labeled placeholder is not accepted.

Legacy materialization is therefore proven safe **when that evidence already
exists**. A historical pack that sealed only a replay manifest and selected
payloads is not enough. It needs a separate, current-production capture before
acquisition; adding that capture flow is intentionally outside this tool.

The minimum generic capture interface would emit:

* a `reviewer-model-visible-role-provenance` document for one declared role,
  fixture id, and legacy binding hash, containing exactly that role's
  model-visible projection fields plus the exact config, prompt, and reviewer
  script SHA-256 values;
* the exact production prompt bytes and SHA-256;
* the exact production config bytes and SHA-256, with its relative `promptFile`
  resolving to those prompt bytes;
* the exact replay manifest/snapshot identity from which those fields were
  observed; and
* a projection resource entry sealing the role-provenance path, length, SHA-256,
  and `role-provenance-<role>` media role.

Until those outputs are independently captured and sealed, readiness is
`blocked`; this materializer does not synthesize them.

```pwsh
./tools/Convert-ReviewerBlindedBenchmarkPack.ps1 `
    -PackRoot <legacy-pack-root> `
    -LegacyProjectionFile <fixture.blinded.json> `
    -Role generalist `
    -RoleProvenanceFile <sealed-role-provenance.json> `
    -ReplaySnapshotPath <exact-snapshot-directory> `
    -ConfigFile <exact-reviewer-config.json> `
    -PromptFile <exact-review-cycle.prompt.md> `
    -ExpectedReplayManifestFileSha256 <64-hex> `
    -ExpectedConfigSha256 <64-hex> `
    -ExpectedPromptSha256 <64-hex> `
    -SecondGeneralistModel <second-generalist-model-id> `
    -ConventionSpecialistModel <specialist-model-id-if-required-or-overridden> `
    -OutputRoot <new-bundle-directory>
```

Re-verification is read-only and requires the transformation manifest's pinned
file SHA-256:

```pwsh
./tools/Convert-ReviewerBlindedBenchmarkPack.ps1 -VerifyOnly `
    -OutputRoot <bundle-directory> `
    -ExpectedTransformationManifestSha256 <64-hex>
```

## No-model acquisition Preflight

Pass `-Preflight` with the same acquisition declaration to run all projection,
replay, config, model, role, candidate, exact HEAD/ref/RepoPath, plan-shape, and
output-collision checks before the mutation boundary. It emits one
`reviewer-blinded-acquisition-readiness` JSON document and exits without
minting a token or plan, taking a lease, creating state, starting a process or
model, or writing to a provider.

The production reviewer itself performs the config-contract validation
in-process. HEAD and the full ref are resolved directly from Git worktree
metadata, so Preflight does not need to start `git`; Acquire repeats the checks
with Git and additionally enforces cleanliness and base ancestry.

The collision result is advisory: a later Acquire still takes the authoritative
atomic `CreateNew` lease and may lose to a concurrent caller after Preflight.

```pwsh
./tools/Invoke-ReviewerBlindedAcquisition.ps1 -Preflight `
    -Role generalist `
    -FixtureProjectionFile <bundle\projection.json> `
    -Model <supported-model-id> `
    -SecondGeneralistModel <second-generalist-model-id> `
    -ConfigFile <bundle\config\reviewer.config.json> `
    -ReplayRoot <bundle\replay> `
    -ReplaySnapshotName <snapshot-name> `
    -ReplayManifestDigest <materialized-manifest-digest> `
    -ExpectedReviewerBaseCommit <40-hex> `
    -PullRequestId <n> `
    -ExpectedHeadCommit <40-hex> `
    -ExpectedRef refs/heads/<branch> `
    -OutputRoot <unused-new-output-path>
```

Plans, readiness documents, and transcript packages sealed before the
second-generalist binding was introduced do not satisfy the current v1
schemas and must be re-acquired; their authenticated manifests cannot be
upgraded in place. Existing materialized benchmark bundles must be
re-materialized with `-SecondGeneralistModel`; this changes their pinned replay
manifest digest.

The verifier's candidate is **derived from sealed discovery evidence, never
from truth**. The operator produces it with
`tools/Get-ReviewerDiscoveryCandidate.ps1`, which authenticates the package
with its acquisition seal key, loads exactly one captured `generalist` or
`specialist` result, and runs the **exact production role-aware candidate
conversion and clustering functions**. Generalist sources must use one of the
configured generalist models. Specialist sources must use exactly the configured
convention-specialist model and can emit only convention-origin candidates.
The verifier additionally requires the *sealed* discovery transcript package
the candidate came from: the supervisor validates that package's HMAC seal,
recursive inventory and result marker, and its exact fixture, snapshot, source
PR, repo, project, commits, config, prompt, script, role, model and result-marker
prefix binding. Unknown or mismatched roles/models, tampering, stale scripts,
cross-fixture/snapshot substitution, and fabricated candidates are refused.
The verifier target itself must be one of the configured generalist pair; the
specialist model is never a verifier. The child then
**re-derives the candidate and clusters from the sealed discovery marker through
those same production functions and requires exact candidate and single-cluster
equality** before it will launch — it never constructs the candidate from truth
or from an arbitrary sibling pass. The source package manifest digest, source
capture-core digest, the
discovery marker digest, the candidate extraction hash and the candidate/cluster
hash are all bound into the authorized plan and the final package. A verifier run
without a valid sealed discovery package, or with a candidate that does not
re-derive from the declared source, is refused — the verifier's target-generalist
pass is rebuilt from that sealed evidence, never from truth.

A dependent verifier may consume a successful specialist package emitted by a
trusted earlier reviewer build without rerunning that specialist. In that case,
pin the package's recorded build with `-ExpectedSourceScriptSha256` during
candidate extraction and `-DiscoverySourceScriptSha256` during capture and
acquisition. Omitting the pin preserves the default same-build requirement.
The source package's config and role prompt must still match the current build;
the exception is deliberately limited to the explicitly pinned reviewer script.
Pre-`sourceProjection` specialist packages are accepted only through their
HMAC-authenticated successful capture core and exact production specialist
marker schema/bindings. When the verifier replay and discovery replay are sibling
benchmark materializations, `-DiscoveryReplayRoot` supplies the authenticated
source replay so both lineages must resolve to the same sealed source manifest.

## Role execution scope

All three roles execute the **full exact production path** end-to-end and seal a
transcript; none stops at the model-launch boundary:

* `generalist` runs the reviewer's generalist pass through the exact prompt
  construction, result-marker parser, schemas, scan windows and subprocess
  boundary, with the generalist bounded fresh-nonce retry. Verification-enabled
  configuration is forwarded so production can build the same layer-5 inputs,
  but acquisition still starts only the authorized generalist role.
* `specialist` runs the reviewer's convention-specialist path through its exact
  production input builder (`New-ReviewerConventionSpecialistInput`) and its own
  bounded fresh-nonce retry, against a convention replay snapshot.
* `verifier` runs the reviewer's reciprocal cross-verification path
  (`Invoke-ReviewerVerificationModelRun`) rebuilt from the sealed discovery
  evidence, with the terminal no-retry policy.

Every role is captured through the same `Invoke-ReviewerModelSubprocess`
boundary; acquisition only records the raw stimulus and never classifies
correctness or delivery eligibility.

## Commands

Acquire a generalist transcript (generic placeholders; no private identifiers):

```pwsh
./tools/Invoke-ReviewerBlindedAcquisition.ps1 `
    -Role generalist `
    -FixtureProjectionFile <path-to-blinded-projection.json> `
    -Model <supported-model-id> `
    -SecondGeneralistModel <second-generalist-model-id> `
    -ConventionSpecialistModel <optional-explicit-override> `
    -ConfigFile <path-to-reviewer.config.json> `
    -ReplayRoot <path-to-replay-root> `
    -ReplaySnapshotName synthetic-pr `
    -ReplayManifestDigest <64-hex-manifest-digest> `
    -ExpectedReviewerBaseCommit <40-hex-base-commit> `
    -PullRequestId <n> `
    -ExpectedHeadCommit <40-hex-head-commit> `
    -ExpectedRef refs/heads/<branch> `
    -OutputRoot <path-to-output-root>
```

Acquire a specialist transcript (the captured `-Model` is the convention
specialist; the surrounding generalist pair is named separately so the exact
production specialist input is built against a convention replay snapshot):

```pwsh
./tools/Invoke-ReviewerBlindedAcquisition.ps1 `
    -Role specialist `
    -FixtureProjectionFile <path-to-blinded-specialist-projection.json> `
    -Model <convention-specialist-model-id> `
    -DiscoveryGeneralistModel <first-generalist-model-id> `
    -SecondGeneralistModel <second-generalist-model-id> `
    -ConfigFile <path-to-convention-reviewer.config.json> `
    -ReplayRoot <path-to-convention-replay-root> `
    -ReplaySnapshotName synthetic-convention-pr `
    -ReplayManifestDigest <64-hex-manifest-digest> `
    -ExpectedReviewerBaseCommit <40-hex-base-commit> `
    -PullRequestId <n> `
    -ExpectedHeadCommit <40-hex-head-commit> `
    -ExpectedRef refs/heads/<branch> `
    -OutputRoot <path-to-output-root>
```

Acquire a verifier transcript. First derive the candidate from the sealed
discovery package with the extraction helper (it runs the exact production
extraction/clustering functions; it never reads truth):

```pwsh
./tools/Get-ReviewerDiscoveryCandidate.ps1 `
    -DiscoveryPackageRoot <path-to-sealed-discovery-package> `
    -SealKeyPath <path-to-acquisition-seal-key> `
    -ExpectedSourceScriptSha256 <trusted-source-reviewer-script-sha256> `
    -OutputFile <path-to-discovery-candidate.json>
```

Then acquire the verifier transcript. The verifier needs that derived candidate
**and** the SEALED discovery package it came from, plus the surrounding
cross-check model set. The child re-derives the candidate from the sealed marker
and requires exact equality before launch:

```pwsh
./tools/Invoke-ReviewerBlindedAcquisition.ps1 `
    -Role verifier `
    -FixtureProjectionFile <path-to-blinded-verifier-projection.json> `
    -CandidateInputFile <path-to-discovery-candidate.json> `
    -DiscoveryPackageRoot <path-to-sealed-discovery-package> `
    -DiscoverySourceScriptSha256 <trusted-source-reviewer-script-sha256> `
    -DiscoveryReplayRoot <path-to-authenticated-discovery-replay-root> `
    -Model <verifier-model-id> `
    -SecondGeneralistModel <second-generalist-model-id> `
    -ConventionSpecialistModel <convention-specialist-model-id> `
    -ConfigFile <path-to-reviewer.config.json> `
    -ReplayRoot <path-to-replay-root> `
    -ReplaySnapshotName synthetic-pr `
    -ReplayManifestDigest <64-hex-manifest-digest> `
    -ExpectedReviewerBaseCommit <40-hex-base-commit> `
    -PullRequestId <n> `
    -ExpectedHeadCommit <40-hex-head-commit> `
    -ExpectedRef refs/heads/<branch> `
    -OutputRoot <path-to-output-root>
```

Re-verify an already-sealed package (or its terminal evidence) without acquiring
a new one:

```pwsh
./tools/Invoke-ReviewerBlindedAcquisition.ps1 -VerifyOnly -OutputRoot <path-to-sealed-package>
```

An omitted `-AuthorizationToken` is minted from a CSPRNG. A weak token (short or
low-entropy) is refused. Production requires a clean worktree at the expected
commit; the `-AllowDirtyWorktree` switch narrowly relaxes only the porcelain
check for development trees, and the exact HEAD/ref/ancestor checks still run.

The `-UseOfflineStubAdapter` switch is **test-only**: it pins execution to the
repository's sealed offline stub adapter for deterministic runs. Omit it for a
real acquisition, where the reviewer uses its production model boundary. The
`-OfflineModelAdapterManifest` may select a stub *behavior* but can never swap
the pinned adapter script.

## Tests

`tools/Test-ReviewerBlindedAcquisition.ps1` is the deterministic suite. It drives
all three roles against the sealed offline stub adapter and uses one local fake
executable to probe the production authentication boundary — **no real model
executable is ever invoked**. It covers: generalist, specialist and
verifier success sealed through their exact production input builders; each
role's marker-failure retry policy (generalist/specialist bounded fresh-nonce
retry, verifier terminal no-retry); terminal schema/binding failure with no
retry; a hanging-grandchild timeout (exit 124 with owned-tree cancellation and
HMAC-authenticated, read-only terminal evidence); crash; stdout saturation; wrong
model/role/candidate/snapshot/fixture/HEAD/ref/token, including a cross-model
mismatch across supported families (e.g. an Opus- vs a GPT-role verifier) and a
cross-source-commit projection whose binding disagrees with the sealed snapshot; the
inner gate's constant-time token SHA-256 **and** HMAC plan-signature checks
(missing-token direct-bypass, SHA mismatch, tampered/replayed plan, wrong output
root, and a non-git RepoPath failing closed on HEAD, all via a direct child
launch); the child's re-derivation of the verifier candidate/cluster from the
sealed discovery marker with exact-equality enforcement; adapter containment
(test-only switch required, pinned-script hash/path enforced); duplicate and
truly-concurrent differing-input launches; a consumed one-shot lease and its
replay refusal; resume refusal; oracle-leakage refusal; asymmetric credential
scrubbing, all three Copilot GitHub auth names, missing-auth classification, and
zero-write telemetry; recursive evidence integrity (seal tamper, missing file,
nested-file injection, reparse-point and empty-directory rejection, recursive
read-only sealing that fails closed on any still-writable bound artifact
(including hidden and deeply nested files), and cross-substitution of an
individually valid file from a separate sealed package, for both success packages
and timeout/crash terminal evidence); and a valid-but-wrong full ref. Verifier-before-valid-discovery is
refused, and the verifier candidate is proven to re-derive from a sealed
discovery package independently of any truth.

The exact production prompt/parser/subprocess path is additionally pinned by
`tools/Test-ReviewerExactPath.ps1`. Both run offline in CI.
