# Owner semantic capability: layer 3

`DevPilot.OwnerCapability` is the preview-only Owner v2 execution boundary over
the generic facade and the normalized acquisition evidence from layers 1 and 2.
It does not import, modify, copy, or replace the deployed reviewer.

Current rollout and authorization status is defined only in the
[authoritative operating state](owner-preview-orchestrator.md#current-operating-state-authoritative).

```text
normalized immutable evidence
        |
wrapper partitions changed MSTest methods
        |
injected semantic runner (one bounded unit at a time)
        |
wrapper validates judgment and owns findings/counts/unknowns
        |
facade preview + normalized observation artifact
        |
wrapper-only provider discussion reconciliation
```

## Capability-specific v2 contract

This contract is specific to the Owner MSTest capability. It is not a new
universal facade contract. The generic facade continues to permit assessments
bound to one or many evidence units, so later relation-aware capabilities can
define their own shapes without changing this adapter.

The wrapper consumes only the facade evidence envelope produced from layer 2.
It requires the exact facade binding and evidence digest plus complete
`identity`, `rule`, and file evidence. It never asks the runner to acquire
files, select a subject, interpret provider state, or recover missing evidence.

For Owner, the wrapper recognizes changed method declarations carrying
`TestMethod` or `DataTestMethod`. Methods that already carry `Owner` are
wrapper-complete and never sent to the runner. Only changed MSTest methods
without `Owner` become semantic runner units. Helpers, unchanged methods, and
declarations outside complete changed spans are never eligible. Changed
comments, assignments, and multi-line invocations in a changed test file are
exposed as stable `notEligible` outcomes without becoming findings or runner
units. Attributed classes are exposed as advisory outcomes and cannot produce
an eligible finding. A changed attributed declaration that the bounded
recognizer cannot classify is an explicit `unknown` outcome, never a clear
result. Missing file or control evidence is exposed as `uncovered`.

Each runner request contains only:

- opaque execution-unit identity;
- capability identity;
- authoritative rule text and wrapper-owned rule reference; and
- method kind, name, attributes, and bounded declaration snippet.

The runner must return exactly one dictionary containing schema version,
execution-unit identity, and one judgment: `compliant`, `violation`, or
`unknown`. It cannot return coordinates, rule provenance, grouping, finding
identity, eligibility, counts, authority, or write instructions. Extra,
missing, duplicated, mutated, or throwing responses make only that unit
`unknown`; valid sibling units remain available to the facade preview.

The wrapper owns immutable subject/head/rule/capability binding, construct and
evidence references, changed-span eligibility, grouping, stable finding IDs,
anchors, deterministic summaries, counts, and unknown accounting. Finding IDs
include the bound head and evidence identity, so identical semantic input is
stable while a different head cannot reuse an old finding identity.

## Preview and observer seam

`ConvertTo-OwnerV2Observation` converts a completed facade result into the
narrow `owner-observation` schema documented by the independent read-only
observer work. The artifact separates comment-eligible violation findings from
non-writer outcomes (`unknown`, `advisory`, `uncovered`, and `notEligible`),
while preserving canonical subject, rule, capability, path, span, construct,
and semantic identities wherever evidence permits. The artifact also states
lifecycle, counts, zero provider/tool writes, and the evidence digest. This
module does not import observer code or schema files and does not create a
branch dependency on that work.

The observation is returned in memory. The preview orchestrator may persist it
under a dedicated v2 preview state root and pass that sanitized local artifact
to the observer. It does not share, migrate, repair, or reinterpret v1 state.

For live Owner findings, the orchestrator may then pass a bounded typed
discussion snapshot to `Resolve-OwnerV2DiscussionReconciliation`. This happens
after the semantic runner has finished, so discussion bodies and provider
ownership metadata never enter the prompt. The wrapper reproduces the approved
V1 writer's exact marker material and fixed comment body: capability
`bpm-test-ownership@1`, writer version 1, repository/PR/source identity,
authoritative rule repository/path/section/commit/SHA with `rs0`, and the
leading-slash path/line/symbol anchor. V2 does not invent a second marker.
The byte contract was transcribed and frozen from the approved V1 writer at
commit `dbc8ddd5`, `src/Agents/reviewer/ApprovedOwnerComments.ps1`
(`Get-ApprovedOwnerDedupeKey` and `Format-ApprovedOwnerComment`).

Live ADO ownership and context are supplied only by the persisted REST
normalizer in `DevPilot.OwnerAdapters`. The semantic/reconciliation module does
not infer text comments from missing enum values, infer reviewer ownership from
an alias, or treat an anchored thread with missing iteration/tracking context
as current. Ambiguous context is an explicit `unknown` reconciliation outcome.
An Owner marker with incomplete REST author identity is likewise `unknown`;
only a complete foreign identity is ignored as an unrelated marker copy.
Read-only validation against two existing V1 Owner comments confirmed that the
writer-created inline threads carry text comment types, the exact configured
reviewer identity, positive change-tracking IDs, and iteration context bound to
their source iteration.

Only one reviewer-owned text comment carrying that marker at the exact anchor
may participate. Arbitrary human text cannot suppress a finding. Exact active
content is `noOp`; one active marker with stale body is `wouldUpdate`; no
usable marker, or an inactive/deleted/outdated thread, is `wouldCreate`.
Foreign, non-text, or deleted marker copies are ignored and cannot suppress an
eligible finding. Duplicate reviewer-owned markers, reviewer-owned markers at a
foreign anchor, source-head mismatch, unknown thread status, or
acquisition/integrity ambiguity are `unknown`. Each finding records a reason,
sanitized thread identity when available, expected body digest, discussion
snapshot digest, and a verified/invalid/unavailable provider marker. Aggregate
effects expose the actionable queue while provider writes and write-tool
invocations remain zero.

For reconciled V2 findings, `providerMarker.availability = available` means the
V1-compatible marker material was deterministically derived and verified; it
does not claim that a provider comment carrying the marker was observed.
Observed-comment presence is represented separately by
`reconciliation.thread.availability` and the classification/reason.

The no-tools launcher layer adds a bounded out-of-process Copilot CLI provider,
a deterministic fake process, and exact offline response replay through the
same parser. Real launch is explicit opt-in and remains fail-closed. The
no-call preflight proves the literal empty tool set and isolated environment.
The supported semantic transport is bounded ordinary `--prompt` argv with the
accepted local process-metadata exposure documented in
`owner-model-runner.md`; no credential is included in the prompt or argv.

## Safety and migration status

This v2 capability remains preview-only, has no delivery adapter, and receives
no scheduler, queue, notification, approval, vote, comment, credential, or
deployment authority from repository data. Host-opt-in live orchestration,
bounded prospective qualification, and a manual canary are complete for the
scoped Owner capability. Read-only discussion reconciliation makes the pending
V1-compatible comment queue accurate; it does not authorize publishing that
queue. Scheduler registration remains an operator action. Sustained
reliability, automatic comments or votes, broader relation-aware rollout, and
consumer migration remain separate decisions. The bounded relation-evidence
demonstration is documented in
[relation-evidence-capability.md](relation-evidence-capability.md).
V1 remains the sole manual approved-comment writer. See the
[authoritative operating state](owner-preview-orchestrator.md#current-operating-state-authoritative)
for current operator deployment evidence and rollback.
