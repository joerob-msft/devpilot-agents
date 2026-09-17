# Owner preview orchestrator: layer 5

`DevPilot.OwnerOrchestrator` is a generic, preview-only layer that composes the
existing Owner v2 modules without adding production authority:

```text
owner-v2-preview-cohort manifest
        |
mandatory absolute external state root
        |
replay acquisition + model replay runner + semantic capability
        |
DevPilot.OwnerPipeline facade
        |
ConvertTo-OwnerV2Observation
        |
v2-only immutable evidence, records, observations, and index
```

The module exports only:

- `Invoke-OwnerV2PreviewPrepare`
- `Invoke-OwnerV2PreviewRun`
- `Get-OwnerV2PreviewStatus`

`tools/Invoke-OwnerV2Preview.ps1` is the manual wrapper. It supports
`prepare`, `run`, `prepare-run`, and `status`, and requires absolute
`-StateRoot` and `-ManifestPath` values. It does not register Task Scheduler,
automation, deployment, notification, vote, comment, summary, or writer work.

## Current operating state (authoritative)

This section is the authoritative current operating state for the Owner v2
stack. Component documents link here rather than restating rollout status.

- **Code-supported modes:** replay and bounded live preview. Live execution
  requires host opt-in with `-EnableLiveModel`, an existing read-only
  acquisition provider, and manifest/provider configuration supplied outside
  repository data, including model identity and credential-environment name.
  Both modes retain exact bindings, bounded execution, explicit `unknown` and
  `notEligible` outcomes, immutable completed-head reuse, and zero writes. The
  repository does not register a scheduler or authorize a deployment.
- **Semantic transport and threat model:** the supported transport is ordinary
  Copilot CLI `--prompt`, capped at 12 KiB. The prompt and argv contain no
  credential; the selected credential is separately mapped into the isolated
  child environment as `COPILOT_GITHUB_TOKEN`. The bounded prompt can be
  transiently visible to local same-user process inspection, endpoint
  monitoring, or administrators. That argv exposure is an accepted residual
  risk for this v1 threat model. Preflight requires `effectiveTools: []`; MCP,
  custom instructions, memory, resume, remote execution/export, plugins,
  repository context, and other ambient inputs remain disabled.
- **Qualification scope:** the schema-version 2
  [sanitized aggregate](owner-parity-summary.json) is the post-PR146
  prospective-cohort snapshot. All eight bounded parity gates passed for the
  applicable locked cohort, and a manual live preview canary subsequently
  passed. This supports the scoped Owner capability; it is not proof of generic
  contextual-review reliability, sustained production equivalence, or
  automatic authorization.
- **Operator deployment state:** scheduler registration and cutover are
  operator actions, not effects of this code. Operator-reported evidence from
  later work outside this PR records that, as of 2026-09-14, the scheduled Owner
  v2 preview service was pinned to exact PR147 head
  `eeb32f38b80d2dd4cc308cd4acaec98e967a506e`, with separate v2 toolkit and
  state. The v1 scheduled preview is disabled but retained for rollback. This
  dated snapshot is deployment evidence, not a repository-created task or
  broader authority.
- **Authority boundary:** v2 remains preview-only and performs zero provider or
  writer writes. V1 remains the sole manual approved-comment writer. Existing
  consumer entry points, configuration, and users were not migrated by this
  stack. Writer compatibility, automatic comments or votes, and any consumer
  migration require separate decisions.
- **State and rollback:** v1 and v2 toolkit/state roots remain separate. Rollback
  is an operator action: stop or disable the v2 preview service and restore the
  retained v1 scheduled preview if needed; no v1 state migration or repair is
  required.

Remaining rollout gates are sustained reliability evidence, an explicit
writer-compatibility and authorization decision, deliberate consumer migration,
and separate proof for any broader contextual-review capability.

## Cohort manifest

The manifest is `schemaVersion: 1`, `kind: owner-v2-preview-cohort`, with a
hard cap of 32 entries. Each entry binds the exact subject, head, target, rule,
capability, model, config, acquisition payload digest, and explicit `replay` or
`live` mode. Replay entries additionally carry only the sanitized values needed
by `New-OwnerModelReplayFixture`: opaque execution-unit id, nonce, input digest,
subject binding, and base64 response bytes.

Preparation validates exact shapes, rejects extra or sensitive writer-like
fields, checks the independently pinned replay acquisition payload digest, and
computes a deterministic state digest from the canonical declaration. Exact
duplicate prepare calls are suppressed; changed head, rule, model, or config
bindings produce distinct state identities.

## State layout

The state root must be absolute, outside this repository, and free of symlink or
reparse traversal where the platform exposes it. The orchestrator derives an
unmistakable v2 preview layout:

```text
owner-v2-preview-state/
  schema-1/
    capabilities/
      <safe capability id>-<capability digest prefix>/
        declarations/
        records/
        evidence/
        observations/
        telemetry/
        index/
        staging/
```

It never reads, writes, repairs, migrates, or interprets v1 keys, queues,
ledgers, audits, or subject directories. Prepare writes immutable declaration
and evidence artifacts and a pending record with same-directory staged flush and
rename. Existing immutable artifacts must byte-match. Run reserves records under
an exclusive lock, increments bounded attempts, writes a running lease, executes
the preview work, and publishes the record, observation, and sorted index
atomically per file. Stale running leases can be recovered; malformed records
are refused.

## Preview-only safety

Replay mode composes:

- `New-OwnerReplayAcquisitionAdapter`
- `New-OwnerModelReplayRunner`
- `New-OwnerV2CapabilityAdapter`
- `Invoke-OwnerReviewPipeline`
- `ConvertTo-OwnerV2Observation`

The facade is invoked without `-AuthorizeDelivery` and without a delivery
adapter. The orchestrator asserts `preview.writeAllowed = false`,
`delivery.state = not-authorized`, `delivery.attempted = false`,
`delivery.writeCount = 0`, and observation
`effects.providerWrites/writeToolInvocations = 0`.

Live declarations remain off by default. `Invoke-OwnerV2PreviewRun` requires
the host-only `-EnableLiveModel` switch plus an existing read-only acquisition
provider. A disabled or not-yet-configured live declaration remains idempotent
for the same inputs and becomes eligible when the host later supplies the
missing opt-in or configuration; completed and model-attempted outcomes remain
terminal. The manifest-derived contract constructs the production acquisition
adapter; the wrapper carries the model id and credential environment name, so
repository data cannot enable launch. It reuses the Copilot provider, preflight,
bounded real runner, and fake-provider seam with bounded argv, `effectiveTools:
[]`, fresh isolation, strict environment allowlisting, disabled ambient
features, deadlines/output caps/process containment, and zero writes. Live
acquisition retains the qualified 64-file/16 MiB/128-read cap. Telemetry is
persisted and bound into observations; preflight failures remain truthful and
completed records immutable. No delivery adapter or authorization is added.

## Historical convergence checklist

The following was the pre-parity implementation checklist. It is retained only
as historical design context; it is not the qualification gate set and does not
claim that the sanitized aggregate measured every orchestrator-state property
listed here. The implemented qualification gates and their evidence are defined
in [Owner parity qualification](owner-parity-qualification.md) and the
[sanitized aggregate](owner-parity-summary.json):

1. exact subject/head/rule/capability/config/model binding parity;
2. acquisition evidence digest parity;
3. eligibility and unknown-accounting parity;
4. finding identity and anchor parity;
5. lifecycle/refusal-state parity;
6. zero-write preview effect parity;
7. deterministic observation/index digest parity; and
8. stale lease/retry/idempotency parity.

The completed bounded cohort does not grant writer compatibility, scheduling,
deployment, notifications, comments, votes, summaries, or cutover authority.
See [Current operating state](#current-operating-state-authoritative) for the
current code, deployment, and remaining-gate distinction.
