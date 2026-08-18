# Escape ledger and budget

An *escape* is a defect that got past review and into a merged coordinator change. This
ledger records every escape since Gate 0, classifies it, and states the budget whose breach
makes the conditional typed control-plane pivot mandatory rather than optional.

A defect that was introduced and caught inside the same unmerged change is a **near miss**,
not an escape, and is recorded separately in `nearMisses`. That separation is load-bearing
rather than tidy: the budget decision reads escape category totals, so folding a pre-merge
finding into them would bias the evidence toward the very pivot the evidence is meant to
decide. The gate enforces the split — a near miss must record `mergedBeforeDetection: false`,
must say why it is not an escape, and must not appear in the budget window.

Near misses have an admission criterion, or the collection becomes a defect log. A finding
is recorded here only if it **invalidated a blocking control or a published assurance
claim** — a gate that could not fail, a detector that reported green without checking, a
count that was wrong in a document someone would act on. An ordinary bug found in review,
including in test code, is not a near miss.

The classification is authored, and git is used to contradict it rather than to establish
it. Under `-VerifyCommits` an escape's `introducedCommit` must be reachable from the
coverage window's end commit, and a near miss's must not be reachable from the mainline
commit it was **classified against** — a fixed `classifiedAgainstCommit`, not the live
window end, so that merging the change containing a near miss cannot retroactively
reclassify it. The baseline was originally the author's choice, and bounding it did not work:
reachability from the window end is satisfied by every commit in the window, and a lower bound
on its date is satisfied by every non-tip commit sharing a calendar day with `detectedOn`.
Either way, naming an old enough baseline made any merged escape look unmerged at a cost of one
field value. Deriving it instead — the mainline as of `detectedOn`, via
`git rev-list -1 --before="<detectedOn> 23:59:59" <windowEnd>` — removed the author's choice but
introduced a worse defect, because the derivation reads the window end: advancing the window to a
later commit on the same day silently changed the expected baseline and false-failed both
honestly filed near misses. A rule whose verdict on unchanged data moves when unrelated history
is appended is not an anchor, so the derivation was removed. The ledger is instead treated as
what it is — a frozen snapshot of a closed window — and `classifiedAgainstCommit` must equal the
coverage window's own pinned `endCommit`. The baseline is then not chosen at all, and advancing
the window authors a *new* snapshot in which the near misses are re-judged, rather than editing
this one in place. `detectedOn` is bounded in turn: it may not precede the day of the finding's
own introducing commit, since a defect cannot be detected before the change that introduced it
exists. Moving a merged incident into `nearMisses` to drop it out of the type-binding total
therefore fails on ancestry rather than on prose, the rule is probed in both directions against
commits the ledger already cites, and controls run the production validator against the coverage
window's start commit, against a commit sharing the detection date, and against a backdated
`detectedOn`.

That is a one-way check, and worth being precise about what it does not do. Reachability
shows a commit is in a history; it does not show that the defective state entered an
integrated revision before detection. A squash or cherry-pick lands the same defect under a
different hash, a non-squash merge of a branch that both introduced and fixed a defect makes
each commit reachable, and a defect on an operational side branch is reachable from neither.
So an ancestry failure proves a misfiling, while an ancestry pass leaves the classification
resting on the recorded rationale. `introducedCommit` is required on both lists precisely so
that a finding cannot leave the check by omitting a field, but its *value* is not tied to the
defect it names — so a merged escape can still be reclassified out of the budget by moving it
into `nearMisses` and rewriting `introducedCommit` to a branch commit unreachable from the frozen
baseline, which moves `typeBinding`, `openDebt` and `inWindow` together on one falsified field.
[`hardening-limitations.md`](hardening-limitations.md) carries these as named residuals.

`category` is the field with the most leverage over the pivot decision, because the trigger
counts type-binding escapes. It cannot be derived — what a defect was is a judgement — so the
gate holds it *consistent* with the detector the same incident cites, in both directions. An
incident detected by a collection-collapse rule (`PSEN004`, `PSEN005`, `PSEN009`, `PSEN011`,
or the cardinality boundary harness) must be `typeBinding`, and one detected by a control-flow
rule (`PSEN001`, `PSEN002`, `PSEN003`, `PSEN006`, `PSEN010`) must be `logic`; conversely, an
escape may not be classified into a category the budget counts unless its detector implies
that category. The converse matters because the forward rule alone left the *inflating* edit
open: the one escape the anchor cannot reach had a free category, so `typeBinding` could be
walked up by a single field. Escaping the anchor is a visible edit rather than a blocked one:
the set of findings whose detector implies nothing must equal the ledger's declared
`categoryAnchorExceptions`, and each entry pins the category the escape is filed under. An
author who rewrites a detector to name nothing recognised, moves the category to one the budget
does not count, and declares the exception with a rationale still passes, and the count still
falls by one — what the rule buys is that this is three coordinated edits in a reviewed list
rather than one silent field. Both fields are still authored, so this is an internal
consistency constraint, not corroboration by independent evidence. It is reported as `categoryDetectorConsistent` — 11 ofthe twelve escapes; `ESC-0011` was found by review of a guard and has no detector to anchor to
— and that count is **not** offered as assurance evidence. Detector family does not establish
root cause.

Escapes are counted on one axis and runtime exposure on another. A *containment escape* is a
defect that entered a merged coordinator change; a *runtime exposure finding* is one that
reached shadow or live execution, whether or not it ever merged. Only the first is budget
evidence, but the second is what the typed-host decision most wants to read, so the near-miss
schema deliberately does **not** pin `reachedShadowOrLive` closed. Pinning it would make the
taxonomy unable to represent a pre-merge live failure at all, which is a way of not counting
it. The two counts stand at **12 containment escapes and 0 runtime-exposed findings across 0
runs**. The zero is a denominator, not an achievement, so the gate publishes it as a
structure — `findingCount`, a per-category breakdown, `shadowRuns`, `liveRuns`, and
`observationStatus: noRuns` — rather than as a bare zero a reader could mistake for
containment. The per-category split matters because a live `external` or `logic` finding is
not the same evidence for a typed host as a live `typeBinding` one.

The machine-readable ledger is [`escape-ledger.v1.json`](escape-ledger.v1.json), validated
against
[`reviewer.escape-ledger.v1.json`](../src/Agents/reviewer/schemas/reviewer.escape-ledger.v1.json)
by `tools/Test-EscapeLedger.ps1`. That check is not a schema check alone: it recomputes
every published count from the incident list, re-evaluates the trigger, and proves with
sabotaged copies of the ledger that a qualifying escape would actually fire it.


> **Scope.** What this does *not* prove is stated in
> [what the hardening layer does not prove](hardening-limitations.md).

## Why a ledger

Each escape in this repository was fixed when it was found, with one exception recorded as
open debt below, and each fix looked sufficient at the time. Read one at a time they are
unrelated accidents. Read together they
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
or live coordinator run has ever been performed. That is a statement about exposure, not
about containment: the budget stands at zero because the denominator is zero, which is why
the exposure obligation below exists.

`ESC-0012` is open debt by design. The rule introduced for `ESC-0002` found eleven further
sites in current source and test code with the same nesting hazard. Every site is
adjudicated individually in the ledger's `sites` array rather than baselined as a block,
because "eleven findings" is not an assessment. Three of them turned out to be live
defects and are fixed in this change: a change-kind accumulator that recorded a
space-joined string instead of separate kinds, a gate revalidation path whose nested thread
list made the duplicate-post fingerprint scan return an empty set, and a capture manifest
that serialized its resource inventory one level too deep. One site is compensated by an
explicit flattening on the following line, one is latent behind a caller-side guard and is
carried as debt because correcting it properly means changing a producer contract and all
of its call sites, and the rest are test-side assertions or deliberate analyzer fixtures.
The remaining findings stay in `tools/testdata/powershell-boundary-baseline.v1.json`; the
boundary gate blocks any new one.

Open debt is the only status that raises a published count, so it is the one an author has an
interest in relabelling. `remediated` already required a remediating commit reachable from the
window end, but `accepted` was unconstrained — flipping one enum value moved the open-debt
count to zero with every check green. A finding marked `accepted` now has to record an
`acceptanceRationale` and an `acceptedOnCommit`, so accepting a risk costs the same kind of
evidence as fixing it. Reachability from the window end alone was not enough: it let a risk be
accepted at a commit that *predates the defect*, and accepting the sole open debt at the commit
that introduced its whole family passed while moving the count to zero. The acceptance commit
must therefore also descend from the finding's own `introducedCommit` and not be dated before
`detectedOn`. A control flips the real open-debt finding to `accepted` and requires the gate to
reject it; a second control accepts it at the commit that introduced it and requires the same.

Each of these rules lives in exactly one validator that both the production loop and its control
call, so neutering the rule makes its own control fail. That protects the rule's body but not
its call site — a control invokes the validator directly and cannot see whether production still
does, and replacing a production assertion with an unconditional success left the gate green
without even moving the check count. Each validator therefore records its entry, and the expected
number of entries — the production invocations the real ledger requires plus the fixed number of
control invocations — is asserted. Deleting any of the seven production call sites now fails a
check that no control can supply.

## Near misses

| ID | Category | Stage | Status | Summary |
| --- | --- | --- | --- | --- |
| `NM-0001` | verificationLogic | deterministic | remediated | Verification tooling failed open: exemption holes, name-collision silencing, container-for-leaf citation matching |
| `NM-0002` | verificationLogic | deterministic | remediated | Two of the checks added to fix `NM-0001` were unfalsifiable, and one asserted a property the analyzer deliberately does not hold |

`NM-0001` is the uncomfortable one, because the thing that failed was the verification
itself. Independent review of this change found three ways its own detectors reported green
while not checking what they claimed. The protected-return exemption counted an unrecognised
exit as *nothing*, so one protected exit silenced the assignment rules for an entire function
even when a sibling exit returned a multi-element pipeline or a cast to an enumerating
collection type. Cross-file name resolution dropped the nesting fact along with the
exemption, so a single unprotected one-line stub in a test file disabled `PSEN011` — the rule
that found the three production defects above — on every production call site of that name,
while raising a false flattening finding there. And the inventory citation check accepted any
segment of a field path, so a citation pointing at the wrong file passed whenever that file
mentioned the generic container name; five live citations were wrong under that rule and are
corrected here.

Each is now pinned by a test that fails on the old behaviour — two exemption-soundness
fixtures, a cross-file gate that builds a producer, a consumer, and a same-named mock and
requires identical findings with and without the mock, and three citation sabotage checks.

`NM-0002` is the sequel, and it is the more useful of the two. The next review round found
that two of the checks written to fix `NM-0001` could not fail. One asserted that a
same-named mock does not raise a flattening finding on a production call site, using an
`@()`-preserved consumer — a form that rule structurally never reports, so the assertion was
always true. It also named a property the analyzer deliberately does not hold: on an
*unwrapped* call site the conservative exemption withdraws and the finding does fire, which
is the accepted imprecision behind two baseline entries. The other two were coverage-clock
sabotage checks of the form "set *n*+1, assert *n*+1 ≠ *n*", which never re-ran the
derivation they were guarding.

The pattern across both is worth naming, because it is the argument for the ledger in
miniature: a check that only ever runs against correct input records confidence rather than
evidence. Both are fixed by making the negative control re-invoke the real derivation —
reverting the exemption/nesting split now makes the cross-file gate fail, and the coverage
clock is extracted into `Measure-LedgerCoverageClock`, which the sabotage checks call on the
mutated ledger with a positive control on the unmutated one. The imprecision that could not
honestly be asserted away is pinned as an expectation instead, so improving it reports here
rather than passing silently.
## The budget

> If **two or more type-binding escapes reach shadow or live execution** within **either the
> last ten merged coordinator changes or the last sixty days**, the conditional
> typed control-plane pivot stops being optional and is scheduled as the next coordinator
> change.

**Read the state below as a dated snapshot, not as a live reading.** The window clock is
hand-maintained — `coordinatorChangesObserved` advances only when an incident carries a
higher ordinal, so an incident-free coordinator change does not move it. The machine-readable
budget says so in its own `operationalStatus: historicalSnapshot` and `asOfCommit` fields, so
a parser cannot pick up the counts without the caveat attached, and the gate refuses to let
the prerequisite be declared in force while the clock's authority is authored ordinals. For the
same reason the window's staleness bound is reported rather than enforced: `commitsBehindHead`
records how far the pinned window end sits behind `HEAD`, but exceeding `staleAfterCommits` only
fails the gate once the prerequisite is in force. Enforcing it against a frozen snapshot would
fail on every later unrelated commit and teach the reader to raise the bound instead of
re-judging the data.

Current state, as of the coverage window's end commit: **0 qualifying escapes, trigger not
fired.** That is because no shadow or live run has ever been performed, not because escapes
were contained.

The threshold is pre-registered for a reason: fixing it now, before any run exists to read,
is what stops it being moved after results are seen. The window is computed, not asserted.
Every incident carries the date it was detected and
the ordinal of the merged coordinator change it was detected under, and
`tools/Test-EscapeLedger.ps1` recomputes the in-window set from those two facts against the
ledger's evaluation date. The combinator is deliberately **either**: an incident counts if
it falls inside the last ten coordinator changes *or* inside the last sixty days. A trigger
that required both windows to agree could be waited out twice over — by going quiet, since
no new changes age nothing out of the ordinal window, and by shipping quickly, since many
changes push incidents out of the ordinal window while they are still days old. A sabotage
case proves that an incident outside both windows stops counting.
the ordinal of the merged coordinator change it was detected under, and
`tools/Test-EscapeLedger.ps1` recomputes the in-window set from those two facts against the
ledger's evaluation date. The combinator is deliberately **either**: an incident counts if
it falls inside the last ten coordinator changes *or* inside the last sixty days. A trigger
that required both windows to agree could be waited out twice over — by going quiet, since
no new changes age nothing out of the ordinal window, and by shipping quickly, since many
changes push incidents out of the ordinal window while they are still days old. A sabotage
case proves that an incident outside both windows stops counting.

The trigger deliberately counts only escapes that reach shadow or live. Deterministic
escapes were caught by the machinery in this repository *after* they had merged, which is
evidence of later detection rather than of prevention; escapes that survive into a run with
real inputs are evidence that it does not.
Shadow counts on equal terms with live: a shadow run exercises the same code and discards
its output, so it preserves the no-write invariant by construction, and treating a shadow
escape as inconsistent with that invariant would make the shadow arm of the trigger
unusable. The literal threshold, stages, and window are asserted by
`tools/Test-EscapeLedger.ps1`, so weakening the trigger requires a reviewed diff rather than
a quiet edit.

`tools/Test-EscapeLedger.ps1` also sabotages copies of the ledger to prove the arithmetic is
real: one qualifying escape must not fire the trigger, two must, two reaching only shadow
must, two `logic` escapes reaching live must not, and incidents outside both windows must
drop out of the count.

## Gate 5 observation

Gate 5 produced **no deliverable decision — a decision yield of zero per cent**. Every
candidate was withheld or reconciled away. The **no-write invariant held**: the run performed
zero writes outside the repository.

Both facts are recorded in the ledger and asserted by the check. Neither is evidence for or
against the pivot, and the earlier framing that read them as opposing arguments was wrong:
decision yield and escape rate answer different questions. Zero yield says the current
control plane has not yet demonstrated end-to-end value. Zero external writes says nothing
about containment quality, because **zero shadow and zero live runs have ever been
performed** — an escape rate measured over no exposure is abstention, not a result.

The ledger therefore records an explicit **exposure obligation**: the conditional decision
is due for re-evaluation only after ten shadow runs have actually been performed, by the
twentieth merged coordinator change. Until then the observed escape rate carries no weight
in either direction, and the check asserts the recorded shadow-run count against the gate
observations so the obligation cannot be quietly declared satisfied.

## Decision status

The typed control-plane pivot is recorded as **conditional**. It is *not* taken in this
change: this change contains no compiled coordinator and runs no models.

Each prerequisite is scored on two separate axes, because an artifact that exists is not the
same as a boundary that is protected. **Built** means the artifact and its gate exist and run
in CI. **In force** means production code actually goes through it today.

| Prerequisite | Built | In force | Evidence |
| --- | --- | --- | --- |
| Cardinality and property corpus over the inventoried collection-bearing stage contracts | yes | no — 0 of 1652 producer-path cells; no stage is driven | `tools/testdata/reviewer-collection-inventory.v1.json` (236 fields, 12 stages), `tools/Test-ReviewerCollectionCardinality.ps1` (7 variants per field, 11 escape shapes, 9 sabotage checks), `tools/testdata/reviewer-collection-cardinality-matrix.v1.json` |
| Versioned file contract for stage child outputs | yes | no — no stage writes or reads its artifacts through it yet | `src/Agents/reviewer/StageContract.ps1`, `src/Agents/reviewer/schemas/reviewer.stage-envelope.v1.json`, `tools/Test-ReviewerStageContract.ps1` |
| Boundary hardening analyzer with a blocking new-violation gate | yes | yes — every push is scanned and any new violation fails CI | `tools/Find-PowerShellEmptyNullHazard.ps1` (11 rules), `tools/Test-PowerShellBoundaryHardening.ps1`, `tools/testdata/powershell-boundary-baseline.v1.json` |
| Escape ledger and budget with a registered trigger | yes | no — counts, window, and trigger are recomputed and enforced in CI, but the window clock is hand-maintained, so the trigger cannot be read as current | this document, `docs/escape-ledger.v1.json`, `tools/Test-EscapeLedger.ps1` |

Three of the four are inert today. That is the honest reading: this layer makes escapes of
the *recognized shapes* detectable and makes the existing ones counted, and only the
analyzer currently acts on live code. It does not yet protect a running stage boundary, and
the budget cannot be read as current until its clock has an authority outside this file.

The pivot becomes mandatory if the budget triggers. It may be reconsidered earlier if these
prerequisites fail to detect a new type-binding escape class — that failure would itself be
an incident here.

## Adding an incident

1. Append an entry to `incidents` in `docs/escape-ledger.v1.json` with the next sequential
   `ESC-nnnn` identifier. Identifiers must be contiguous; the check enforces it.
2. Set `executionStage` honestly. `reachedShadowOrLive` must agree with it — the check
   enforces that too.
3. Set `detectedOn` and `coordinatorChangeOrdinal`. These are what the rolling window is
   computed from; an incident with no date does not age.
4. Name a `detector` and a `regressionGuard`, each citing a file that exists. A remediated
   incident with no guard is an incident waiting to recur.
5. Update `budget.state` to the recomputed values, or let the check tell you what they
   should be.
6. Add a row to the table above. The check fails if the ledger and this document disagree
   about which incidents exist.
