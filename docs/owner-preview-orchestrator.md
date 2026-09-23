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

The same state machine also accepts the separately bounded
`relation-v2-preview-cohort` manifest through
`tools/Invoke-RelationV2Preview.ps1`. That wrapper exposes only `prepare-run`
and `status`, caps cohorts at 10 entries, and dispatches to
`DevPilot.RelationEvidence` with an injected read-only provider. Existing Owner
manifest behavior and scheduled deployment remain unchanged; relation
deployment is separate.

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
- **Authority boundary:** scheduled v2 remains preview-only and performs zero
  provider or writer writes. Live Owner observations can read bounded PR
  discussions after semantic execution and classify the V1-compatible queue as
  `wouldCreate`, `wouldUpdate`, `noOp`, or explicit `unknown`; that read-only
  queue does not grant delivery authority. A separate manual v2 approved-comment
  command can export proposals, sign an exact operator selection, dry-run it,
  and only then publish when the operator separately supplies `-Publish`.
  Nothing adds the command to a scheduler or gives a model, dashboard, provider
  adapter, or observation delivery authority. Automatic comments remain
  unauthorized.
- **State and rollback:** v1 and v2 toolkit/state roots remain separate. Rollback
  is an operator action: stop or disable the v2 preview service and restore the
  retained v1 scheduled preview if needed; no v1 state migration or repair is
  required.

After this layer is accepted, deployment must update the external live provider
to acquire full REST thread and iteration pages and call the documented
`ConvertTo-OwnerAzureDevOpsDiscussionPage` function before pinning the new
toolkit. The configured reviewer GUID, descriptor, and full UPN remain external
immutable deployment inputs. Existing semantic results, model execution state, attempts,
identity, and telemetry remain immutable. A scheduled run with the new provider
refreshes only the discussion reconciliation overlay and durable result digest,
including upgrading a pre-reconciliation completed observation, without
starting the model again. That deployment action is intentionally outside this
repository change.

Remaining rollout gates are sustained reliability evidence, explicit
per-batch human publish authorization, deliberate consumer migration, and
separate proof for any broader contextual-review capability.

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

Record schema 2 owns `modelExecutionState` as a durable execution-phase fact.
New records start at `notAttempted`; immediately before the first semantic
runner call, the orchestrator atomically changes the leased record to
`attempted`. The state never moves backward. Preflight, credential, containment,
provider availability, and other environment failures before that boundary
remain explicitly `notAttempted`. Any call that may have reached the model is
conservatively `attempted`, including crash recovery after the transition.
An expired running lease already marked `attempted` is closed as
`interrupted-after-model-attempt` without another model call.
Legacy schema-1 records are fail-closed unless they are pristine pending records
with zero attempts and no result or failure, which are upgraded in place to
schema 2 with `notAttempted`.

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

For live Owner entries with eligible findings, the orchestrator performs one
additional wrapper-only phase after the facade/model path: bounded
`GetDiscussionPage` acquisition followed by V1-compatible marker/body/anchor
reconciliation. The discussion snapshot is never model evidence. Its canonical
digest is recorded as an observation source artifact, and each finding carries
an actionable classification, reason, expected body digest, and sanitized
thread identity. Discussion acquisition or integrity failure changes only the
dedupe result to `unknown`; it does not change the semantic disposition,
lifecycle verdict, lease, retry boundary, or model-execution state.
Live runs require the Azure DevOps REST provenance contract from
`ConvertTo-OwnerAzureDevOpsDiscussionPage`; a provider page without the pinned
mapping digest, exact reviewer-identity digest, current iteration, typed-page
digest, and raw REST provenance digest is rejected. The lossy Agency MCP thread
projection is not a supported live discussion source.
Later runs with a live provider refresh this discussion-only overlay even when
the semantic record is already completed. They verify the persisted observation
against its durable digest, perform no preflight or model call, retain the same
attempt count and telemetry, and replace rather than accumulate discussion
snapshot provenance. Transient failures are therefore retryable without
repeating semantic execution.

Completed refreshes use an optimistic compare-and-swap: the provider read runs
outside the capability lock, then publication rechecks the completed record and
prior result digest. A small bounded journal in `staging/` fences the observation
and record updates. If the process stops after writing the observation but
before updating the record digest, the next run accepts only the journal's exact
old/new digest pair, completes the interrupted record update, removes the
journal, and continues. Any other mismatch remains a durable-state integrity
failure. Provider acquisition, reconciliation, and refresh publication failures
are contained to that entry and do not skip later cohort entries; durable-state
integrity failures retain the orchestrator's existing fail-closed whole-run
behavior.

Live declarations remain off by default. `Invoke-OwnerV2PreviewRun` requires
the host-only `-EnableLiveModel` switch plus an existing read-only acquisition
provider. A disabled or not-yet-configured live declaration remains idempotent
for the same inputs and becomes eligible when the host later supplies the
missing opt-in or configuration. An incomplete or unknown live record can be
retried only when its schema-2 execution state is explicitly `notAttempted`,
attempts remain, all manifest-derived identity and state digests still match,
and current opt-in, acquisition, and model-provider configuration are present.
The non-recoverable denylist is limited to durable-state integrity failure,
model binding mismatch, rule evidence unavailable or misbound, evidence-cap
exhaustion, relation outcome unknown, and orchestrator refusal. Completed and
model-attempted outcomes remain terminal; model-runner transport and schema
retry behavior is unchanged and semantic disagreement is never retried.

Each orchestration attempt with telemetry writes an immutable
`<identity>.attempt-NNNN.json` audit artifact as well as the current
`<identity>.json` telemetry view. Repair therefore creates a new bounded record
without deleting the prior failure evidence. The manifest-derived contract
constructs the production acquisition
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

The completed bounded cohort and discussion reconciliation do not grant
scheduling, deployment, notifications, comments, votes, summaries, or cutover
authority.
See [Current operating state](#current-operating-state-authoritative) for the
current code, deployment, and remaining-gate distinction.

## Manual approved-comment flow

`tools/Invoke-ApprovedOwnerV2Comment.ps1` is the only v2 comment-writer entry
point. It consumes one exact completed Owner v2 record, observation, telemetry
view, declaration, and discussion overlay from the durable preview state. It
rejects relation results, incomplete findings, advisory/class/helper/unknown
outcomes, non-actionable reconciliation states, modified state files, and
selections larger than five. The scheduler and preview commands never invoke
it.

The operator uses a private root outside the repository. Initialization creates
a 32-byte HMAC key in that owner-only root. The unsigned review package contains
the exact proposed body and V1-compatible marker for every eligible finding; it
does not authorize delivery:

```powershell
$tool = '.\tools\Invoke-ApprovedOwnerV2Comment.ps1'

& $tool initialize-key `
    -ApprovalRoot C:\private\owner-v2-approved-comments

& $tool export `
    -ApprovalRoot C:\private\owner-v2-approved-comments `
    -StateRoot C:\private\owner-v2-preview-instance `
    -Identity <64-lowercase-hex-state-identity> `
    -ToolkitConfigPath C:\private\owner-v2-preview-instance\config\owner-v2-live-config.json `
    -ReviewPackagePath C:\private\owner-v2-approved-comments\reviews\review.json
```

After reviewing the exact bodies, paths, lines, symbols, rationales, markers,
construct identities, and digests, the operator signs one to five explicit
finding IDs. The command never infers "all findings". The GUID, descriptor, UPN,
and reason identify the exact approving operator:

```powershell
& $tool approve `
    -ApprovalRoot C:\private\owner-v2-approved-comments `
    -StateRoot C:\private\owner-v2-preview-instance `
    -Identity <state-identity> `
    -ToolkitConfigPath C:\private\owner-v2-preview-instance\config\owner-v2-live-config.json `
    -ReviewPackagePath C:\private\owner-v2-approved-comments\reviews\review.json `
    -ApprovalPackagePath C:\private\owner-v2-approved-comments\approvals\batch-1.json `
    -FindingId <finding-1>,<finding-2> `
    -OperatorId <reviewer-guid> `
    -OperatorDescriptor <reviewer-descriptor> `
    -OperatorUpn <reviewer-upn> `
    -Reason 'Reviewed the exact proposed comments.' `
    -Approve
```

Invocation defaults to dry-run and requires `-Approve` again. The direct Azure
DevOps provider re-reads the active PR, source head, target commit/ref, current
iteration and change tracking IDs, changed right-side line spans, full bounded
REST discussions, and exact reviewer identity. It then recomputes the
repository-owned discussion snapshot and marker classification. Any state,
head, target, anchor, rule, implementation, result, snapshot, identity,
pagination, or signature drift fails closed:

```powershell
& $tool invoke `
    -ApprovalRoot C:\private\owner-v2-approved-comments `
    -StateRoot C:\private\owner-v2-preview-instance `
    -Identity <state-identity> `
    -ToolkitConfigPath C:\private\owner-v2-preview-instance\config\owner-v2-live-config.json `
    -ProviderConfigPath C:\private\owner-v2-preview-instance\config\owner-v2-live-config.json `
    -ApprovalPackagePath C:\private\owner-v2-approved-comments\approvals\batch-1.json `
    -Approve
```

Only a later, explicit operator decision adds `-Publish`. Updates additionally
require `-ApproveUpdate` both when signing and invoking. Before every individual
write the command repeats the full read-only validation. It writes only the
selected anchored text comment, performs an immediate REST readback, and records
immutable HMAC-signed intent and outcome audits. An interrupted intent is
reconciled from the live marker/body before retry, preventing duplicate posts.
The command never votes, changes PR status, sends notifications, publishes
summaries, or resolves unrelated threads.

After publication, run the scheduled v2 preview normally to reconcile the new
discussion snapshot into the Owner observation. Expected selected findings then
become `noOp`. Rollback is operational: stop using the manual writer, preserve
the signed approval/intents/outcomes for audit, and refresh the observation.
Comments already created are provider records and must not be silently deleted
or hidden by this tool; any correction requires another explicit signed update
approval.
