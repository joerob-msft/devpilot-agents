# Owner semantic capability: layer 3

`DevPilot.OwnerCapability` is the preview-only Owner v2 execution boundary over
the generic facade and the normalized acquisition evidence from layers 1 and 2.
It does not import, modify, copy, or replace the deployed reviewer.

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
without `Owner` become semantic runner units. Helpers, unchanged methods,
declarations outside complete changed spans, and other constructs are never
eligible. Attributed classes are represented as advisory `unknown`
assessments and cannot produce an eligible finding. A changed attributed
declaration that the bounded recognizer cannot classify is explicit `unknown`,
never a clear result.

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
observer work. The artifact states lifecycle, bindings, findings, counts,
unknowns, zero provider/tool writes, and the evidence digest. This module does
not import observer code or schema files and does not create a branch
dependency on that work.

The observation is returned in memory. A later integration may persist it
under a dedicated v2 preview state root and pass that sanitized local artifact
to the observer. It must not share, migrate, repair, or reinterpret deployed v1
state.

Layer 4 adds a bounded out-of-process test-child adapter and exact offline
response replay through the same parser. Live model launch remains fail-closed
until a model CLI can prove a literal read-only/no-tools mode. See
`owner-model-runner.md`.

## Safety and migration status

Frozen v1 remains deployed and solely writer-eligible. This v2 capability is
shadow/preview-only, has no delivery adapter, and receives no host, model,
provider, scheduler, queue, notification, approval, vote, comment, credential,
or deployment authority. The committed runner and corpus are deterministic,
offline, and generic.

Later layers must separately add and validate:

- a parallel scheduler/orchestrator with separate preview state;
- a sustained parity cohort;
- a proven no-tools real model launch mode;
- writer compatibility;
- relation-aware capabilities; and
- an explicit cutover and rollback plan.

No production writer or deployment switch should consume v2 results before
those gates are complete.
