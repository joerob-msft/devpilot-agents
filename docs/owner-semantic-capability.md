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
scoped Owner capability. Scheduler registration remains an operator action.
Sustained reliability, writer compatibility, automatic comments or votes,
relation-aware capabilities, and consumer migration remain separate decisions.
V1 remains the sole manual approved-comment writer. See the
[authoritative operating state](owner-preview-orchestrator.md#current-operating-state-authoritative)
for current operator deployment evidence and rollback.
