# Relation-evidence contextual capability

`DevPilot.RelationEvidence` adds one preview-only contextual assessment over the
existing generic facade, acquisition envelope, semantic runner, validation,
preview, observation, and Owner v2 state machinery. It does not add another
orchestrator, queue, model provider, process supervisor, delivery adapter, or
writer.

Current rollout and authorization status remains defined by the
[authoritative Owner v2 operating state](owner-preview-orchestrator.md#current-operating-state-authoritative).
This capability does not change the scheduled Owner service or its state.
Deployment remains a separate operator action.

## Scheduler-callable preview

`tools/Invoke-RelationV2Preview.ps1` exposes only `prepare-run` and `status`.
It requires an absolute, separate state root; an absolute external manifest;
an injected `DevPilot.OwnerAdapters` read-only provider; and explicit live-model
opt-in with either an injected model provider or model/credential-environment
selection. It reuses `DevPilot.OwnerOrchestrator` leases, bounded attempts,
atomic publication, immutable terminal reuse, telemetry, and per-entry failure
isolation. It does not register or modify a scheduler.
The wrapper exits successfully when orchestration itself succeeds; per-entry
`completed`, `incomplete`, or `unknown` states in its returned records are the
authoritative semantic result. Validation or state-integrity failures throw.

The external `relation-v2-preview-cohort` manifest is schema version 1 and has
a hard cap of 10 entries. Each entry binds:

- exact subject, source head, target commit/ref, rule source, capability,
  model, and configuration identities;
- one neutral relationship question, claim identity, severity, policy, and
  wrapper-selected anchor role; and
- up to 16 required or optional evidence-role selectors, each with up to four
  exact or suffix path patterns and a declared source/guidance/test role.

The configuration digest covers the routing declaration. Repository-specific
paths and evidence roles stay in that external manifest; code contains no
repository or method routing. The provider supplies exact changed-file and rule
bytes through the existing production acquisition envelope. The wrapper
constructs evidence refs, source digests, spans, applicability, slots, and the
anchor. The manifest cannot provide a verdict or finding.

Applicability is positive only when a declared trigger selector matches and all
required roles resolve unambiguously. A missing, ambiguous, incomplete, or
oversize decisive role yields `unknown` without a model attempt. The wrapper
does not fabricate warm or corrected evidence. Model-visible evidence is capped
at 10,000 bytes, the relation request at 9,000 bytes, and the existing Copilot
prompt at 12 KiB; over-budget evidence is never silently truncated.

Completed exact declarations are terminal and are reused without another
provider or model call. Private state persists the exact acquired snapshot,
bounded relation request, observation, runner telemetry, and immutable record.
Observations include citations and bounded explanation when available,
attempt/call/latency telemetry, explicit unavailable cost status, and the
limitations `static-source-assessment` and `runtime-behavior-unverified`.

## Bounded contract

The versioned request declares one capability and rule identity, an exact
subject/head binding, wrapper-issued evidence refs, bounded relationship
claims, applicability, required role slots, one wrapper-selected anchor per
claim, and budgets.
Each evidence ref binds type, path, span, digest, provenance, role labels,
completeness, and bounded content. Canonical JSON and digests make equivalent
requests stable and make changed evidence or bindings distinguishable.

This is a capability-specific contract, not a universal review language. The
wrapper owns evidence acquisition, identities, coordinates, provenance,
eligibility, anchors, severity, policy, finding IDs, budgets, validation,
preview, and zero-write authority. The model sees each referenced evidence item
once with the roles it serves and returns only:

- `violation`, `compliant`, or `unknown`;
- unique citations to supplied evidence refs;
- a short explanation; and
- an optional bounded remediation direction.

Missing required evidence or unknown applicability makes only that claim
`unknown` without launching the model. Malformed model output also isolates to
that claim, so valid sibling assessments survive. The observation reports an
empty effective tool set, zero provider writes, zero write-tool invocations,
delivery not authorized, and no comment, vote, notification, or writer path.

`New-RelationEvidenceModelProcessRunner` reuses the bounded Copilot CLI
transport, process containment, response binding, parser, retry policy, and
telemetry described in [the model-runner documentation](owner-model-runner.md).
Real launch remains explicit opt-in.

## Contextual demonstration

The committed fixtures use neutral projection, metadata-cache, filtering, and
public-response relationships. They cover a cold relational violation, a warm
compliant control that preserves ordinary configuration, a missing-evidence
`unknown`, and a corrected synthetic variant. No repository-specific detector
computes those verdicts.

The source-pinned private evaluation used the same contract and parser. Its
sanitized aggregate is recorded in
[relation-evidence-summary.json](relation-evidence-summary.json):

| Case | Result | Accepted model attempts | Model-input bytes | Latency |
|---|---|---:|---:|---:|
| Source-pinned cold relationship | `violation` | 1 | 9,676 | 33,874 ms |
| Synthetic warm control | `compliant` | 1 | 3,884 | 24,754 ms |
| Missing decisive evidence | `unknown` | 0 | 0 | 0 ms |

Six earlier evaluation attempts are retained in the private attempt record:
two accepted pre-hardening results superseded by required security changes, one
private reporting loss, one schema-invalid response, and two pre-start transport
failures. The final accepted evaluations used `claude-sonnet-5`,
`effectiveTools: []`, zero provider writes, and zero delivery writes. Cost was
unavailable.

The private candidate was current at its exact source during revalidation, but
the target branch had advanced. The demonstrated conclusion is therefore a
static exact-source relationship: it does not claim an observed runtime leak.
Startup and request ordering remain unverified, and no finding was posted or
fixed.

This demonstrates one bounded contextual multi-evidence case and its controls.
It is not evidence of general reviewer reliability, sustained production
equivalence, or writer readiness.
