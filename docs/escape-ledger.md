# Escape ledger and budget

An *escape* is a defect that got past review and into a merged coordinator change. This
ledger records every escape since Gate 0, classifies it, and states the budget whose breach
makes the conditional typed control-plane pivot mandatory rather than optional.

The machine-readable ledger is [`escape-ledger.v1.json`](escape-ledger.v1.json), validated
against
[`reviewer.escape-ledger.v1.json`](../src/Agents/reviewer/schemas/reviewer.escape-ledger.v1.json)
by `tools/Test-EscapeLedger.ps1`. That check is not a schema check alone: it recomputes
every published count from the incident list, re-evaluates the trigger, and proves with
sabotaged copies of the ledger that a qualifying escape would actually fire it.

## Why a ledger

Each escape in this repository was fixed the day it was found, and each fix looked
sufficient at the time. Read one at a time they are unrelated accidents. Read together they
are a distribution, and the distribution is what decides whether the control plane should
stay in a dynamically-typed shell language. A ledger is the only way to see the
distribution, and a budget is the only way to make it produce a decision instead of a
feeling.

`ESC-0011` is the entry that justifies the format. There, the defect was not in the product
code but in the regression guard: the first guard for an empty-aggregate crash asserted the
fixed site rather than the property, so the same defect passed it at a sibling site. Guards
that escape are escapes.

## Classification

Every incident carries a category and the furthest execution stage it reached.

| Category | Meaning |
| --- | --- |
| `typeBinding` | The runtime bound a value to the wrong shape — a collection collapsed to a scalar or to null, a scalar widened to a collection, or a collection nested inside another. The logic was right for the shape the author intended. |
| `logic` | The shape was preserved but the computation, guard, or control flow was wrong, including state captured at the wrong time by a closure. |
| `modelProtocol` | A model produced output that did not satisfy the contract the caller assumed. |
| `supervision` | A reviewer approved a change whose defect was visible in the diff or in existing test output. |
| `external` | A dependency, host, or runtime behaved differently from its documented contract. |

| Execution stage | Meaning |
| --- | --- |
| `deterministic` | Reached only paths that run with no model and no external writes: unit and structural tests, replay, dry runs. |
| `shadow` | Reached a run that invoked models against real inputs but discarded the output. |
| `live` | Reached a run whose output was delivered outside the repository. |

Incidents are identified by this repository's own public commit hashes. No external review
identifiers, work-item numbers, programme code names, or addresses appear in the ledger, and
`tools/Test-EscapeLedger.ps1` fails if any are introduced.

## Current incidents

| ID | Category | Stage | Status | Title |
| --- | --- | --- | --- | --- |
| `ESC-0001` | typeBinding | deterministic | remediated | Empty fingerprint set returned as null |
| `ESC-0002` | typeBinding | deterministic | remediated | Anchor arrays nested one level deeper by array-subexpression wrapping |
| `ESC-0003` | typeBinding | deterministic | remediated | Specialist capture plan arrays collapsed across the plan boundary |
| `ESC-0004` | typeBinding | deterministic | remediated | Verifier JSON value shapes not preserved on round trip |
| `ESC-0005` | typeBinding | deterministic | remediated | Shared inventory return flattened at the boundary |
| `ESC-0006` | logic | deterministic | remediated | Source transport helper closures captured the wrong binding |
| `ESC-0007` | logic | deterministic | remediated | Live source closure captured a mutated loop variable |
| `ESC-0008` | logic | deterministic | remediated | Recovery reader closure captured state after reassignment |
| `ESC-0009` | logic | deterministic | remediated | Aggregate over an empty selection crashed under strict mode |
| `ESC-0010` | logic | deterministic | remediated | Second all-withheld aggregate crash in a sibling renderer |
| `ESC-0011` | supervision | deterministic | remediated | Empty-aggregate guard accepted a same-block dominance loophole |
| `ESC-0012` | typeBinding | deterministic | openDebt | Latent protected-return wrapping sites present in current code |

Six of the twelve are type-binding. None reached shadow or live execution, because no shadow
or live coordinator run has ever been performed — which is the same fact recorded as the
no-write invariant below, and the reason the budget currently stands at zero.

`ESC-0012` is open debt by design. The rule introduced for `ESC-0002` finds eleven further
sites in current source and test code with the same nesting hazard. They are recorded with
rationale in `tools/testdata/powershell-boundary-baseline.v1.json`; the boundary gate blocks
a twelfth. Mechanically rewriting eleven unrelated call sites is not the job of a
prerequisite layer, and doing it blind would risk introducing exactly the class of defect the
layer exists to detect.

## The budget

> If **two or more type-binding escapes reach shadow or live execution** within a window of
> **ten merged coordinator changes or sixty days**, whichever comes first, the conditional
> typed control-plane pivot stops being optional and is scheduled as the next coordinator
> change.

Current state: **0 qualifying escapes, trigger not fired.**

The trigger deliberately counts only escapes that reach shadow or live. Deterministic
escapes are caught by the machinery in this repository and are evidence that the machinery
works; escapes that survive into a run with real inputs are evidence that it does not. The
literal threshold, stages, and window are asserted by `tools/Test-EscapeLedger.ps1`, so
weakening the trigger requires a reviewed diff rather than a quiet edit.

`tools/Test-EscapeLedger.ps1` also sabotages copies of the ledger to prove the arithmetic is
real: one qualifying escape must not fire the trigger, two must, and two `logic` escapes
reaching live must not.

## Gate 5 observation

Gate 5 produced **no deliverable decision — a decision yield of zero per cent**. Every
candidate was withheld or reconciled away. The **no-write invariant held**: the run performed
zero writes outside the repository.

Both facts are recorded in the ledger and asserted by the check. They matter to the pivot
decision in opposite directions. Zero yield means the current control plane has not yet
demonstrated end-to-end value, which argues against spending the pivot now. Zero external
writes means every escape so far has been contained, which argues that the current
containment is adequate — and both readings are only defensible while the budget stands at
zero.

## Decision status

The typed control-plane pivot is recorded as **conditional**. It is *not* taken in this
change: this change contains no compiled coordinator and runs no models.

| Prerequisite | Complete | Evidence |
| --- | --- | --- |
| Cardinality and property corpus over every collection-bearing stage contract | yes | `tools/testdata/reviewer-collection-inventory.v1.json` (236 fields, 12 stages), `tools/Test-ReviewerCollectionCardinality.ps1` (7 variants per field, 11 escape shapes, 9 sabotage checks), `tools/testdata/reviewer-collection-cardinality-matrix.v1.json` |
| Versioned file contract for stage child outputs | yes | `src/Agents/reviewer/StageContract.ps1`, `src/Agents/reviewer/schemas/reviewer.stage-envelope.v1.json`, `tools/Test-ReviewerStageContract.ps1` |
| Boundary hardening analyzer with a blocking new-violation gate | yes | `tools/Find-PowerShellEmptyNullHazard.ps1` (11 rules), `tools/Test-PowerShellBoundaryHardening.ps1`, `tools/testdata/powershell-boundary-baseline.v1.json` |
| Escape ledger and budget with a registered trigger | yes | this document, `docs/escape-ledger.v1.json`, `tools/Test-EscapeLedger.ps1` |

The pivot becomes mandatory if the budget triggers. It may be reconsidered earlier if these
prerequisites fail to detect a new type-binding escape class — that failure would itself be
an incident here.

## Adding an incident

1. Append an entry to `incidents` in `docs/escape-ledger.v1.json` with the next sequential
   `ESC-nnnn` identifier. Identifiers must be contiguous; the check enforces it.
2. Set `executionStage` honestly. `reachedShadowOrLive` must agree with it — the check
   enforces that too.
3. Name a `detector` and a `regressionGuard`, each citing a file that exists. A remediated
   incident with no guard is an incident waiting to recur.
4. Update `budget.state` to the recomputed values, or let the check tell you what they
   should be.
5. Add a row to the table above. The check fails if the ledger and this document disagree
   about which incidents exist.
