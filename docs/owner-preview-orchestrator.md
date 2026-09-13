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
provider. The manifest-derived contract constructs the production acquisition
adapter; the wrapper carries the model id and credential environment name, so
repository data cannot enable launch. It reuses the Copilot provider, preflight,
bounded real runner, and fake-provider seam with bounded argv, `effectiveTools:
[]`, fresh isolation, strict environment allowlisting, disabled ambient
features, deadlines/output caps/process containment, and zero writes. Live
acquisition retains the qualified 64-file/16 MiB/128-read cap. Telemetry is
persisted and bound into observations; preflight failures remain truthful and
completed records immutable. No delivery adapter or authorization is added.

## Next convergence layer

The next convergence layer must incorporate the reviewed PR128 observer delta
or an equivalent dependency, then run v1 and v2 on identical pinned evidence.
It must enforce the eight recorded parity gates:

1. exact subject/head/rule/capability/config/model binding parity;
2. acquisition evidence digest parity;
3. eligibility and unknown-accounting parity;
4. finding identity and anchor parity;
5. lifecycle/refusal-state parity;
6. zero-write preview effect parity;
7. deterministic observation/index digest parity; and
8. stale lease/retry/idempotency parity.

Writer compatibility, scheduled-task registration, production deployment,
notifications, comments, votes, summaries, and cutover remain separate gates.
