# Escape ledger and budget

An *escape* is a defect that got past review and into a merged coordinator change. An
*integration incident* is a defect observed in an authorized Gate 5 lineage whose private
source is represented only by a public-safe evidence digest. This ledger preserves every
historical escape and near miss from version 1, records the post-snapshot integration
incidents separately, and states the budget whose breach makes the typed control-plane pivot
mandatory.

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
version 1 snapshot's pinned `endCommit`. Version 2 advances the operational window without
rewriting that historical classification. `detectedOn` is bounded in turn: it may not precede the day of the finding's
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
resting on the recorded rationale. `introducedCommit` remains required on both historical lists. Version 2 additionally pins
every historical ID, list membership, category, execution stage, and introducing commit in
`classificationBaseline`, which is digest-bound to the version 1 snapshot. Moving an escape
to `nearMisses` or rewriting its introducing commit now fails a visible baseline validation
and two sabotage cases. CI reads the retained, frozen v1 artifact,
recomputes its SHA-256 over the LF-normalized file, and requires it to equal
`previousSnapshot.ledgerSha256`; the digest is therefore an independently checked historical
anchor rather than a literal repeated only inside version 2.

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
`categoryAnchorExceptions`, and each entry pins the category the escape is filed under.
Declared exceptions are first-class data: each pins the finding's category, is validated
against exactly one finding, is reported in the machine-readable counts, and remains eligible
for the budget when the finding says it is. This is still an internal consistency constraint,
not independent proof of root cause.

Escapes are counted on one axis and runtime exposure on another. A *containment escape* is a
defect that entered a merged coordinator change; a *runtime exposure finding* is one that
reached shadow or live execution, whether or not it ever merged. Historical near misses are
not budget evidence; explicitly eligible integration incidents are. Runtime exposure is what
the typed-host decision most wants to read, so the near-miss
schema deliberately does **not** pin `reachedShadowOrLive` closed. Pinning it would make the
taxonomy unable to represent a pre-merge live failure at all, which is a way of not counting
it. The counts now stand at **12 historical containment escapes, 2 historical near misses, and
6 post-snapshot integration incidents**. All six integration incidents reached a Gate 5
shadow or live-input preparation lineage; one lineage reached real discovery. Four are
budget-eligible type-binding incidents, while two private recipe/finalizer failures are
recorded as budget-ineligible logic/tooling evidence.

The machine-readable ledger is [`escape-ledger.v2.json`](escape-ledger.v2.json), validated
against
[`reviewer.escape-ledger.v2.json`](../src/Agents/reviewer/schemas/reviewer.escape-ledger.v2.json)
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
| `shadow` | Reached an authorized no-delivery integration lineage, including preparation; model use is reported separately by the run counts and evidence. |
| `live` | Reached a run whose output was delivered outside the repository. |

Historical incidents are identified by public repository commits; integration incidents use
public-safe evidence digests. No external review identifiers, work-item numbers, programme
code names, private paths, or addresses appear in the ledger, and
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

The historical table is unchanged from the digest-bound version 1 snapshot.

Version 2 makes the Gate 5 integration meaning of `shadow` explicit: entry into an authorized
no-delivery lineage, including its preparation and finalization phases, is exposure for this
budget even when models were not launched. This is not a claim of model execution. The sealed
snapshot reports model runs independently, and the four qualifying incidents are the
type-binding failures in that lineage rather than the two tooling/logic failures.

### Post-snapshot Gate 5 integration incidents

| ID | Category | Phase | Budget eligible | Title |
| --- | --- | --- | --- | --- |
| `INT-0001` | typeBinding | live-capture preparation | yes | Dynamic source wrapper lost required identity bindings |
| `INT-0002` | typeBinding | shadow post-discovery | yes | Empty discovered-fingerprint set collapsed to null |
| `INT-0003` | typeBinding | shadow preparation | yes | Private configuration arrays collapsed during shadow preparation |
| `INT-0004` | typeBinding | shadow preparation | yes | Empty exact-key difference collapsed before Count |
| `INT-0005` | logic | shadow preparation | no | Private snapshot recipe used non-contract identity keys |
| `INT-0006` | logic | snapshot finalization | no | Private snapshot finalizer depended on an unavailable helper |

The private recipe and finalizer failures remain visible without inflating the type-binding
count. Evidence is referenced only by sealed artifact or coordinator evidence SHA-256; no
private review identifier, path, or code identifier is published.

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
control invocations — is asserted. Each call is also written inside the assertion it feeds, so
neutering the assertion removes the call rather than orphaning it and leaving the count intact.
Deleting or neutering any of the seven production call sites now fails a check that no control
can supply. The gate now parses its own AST and requires every shared validator call to sit inside the
verdict argument of `Assert-Ledger`; a sabotage copy adds `-or $true` and must be rejected.
This closes the known silent verdict-discard form without pretending the test script is
tamper-proof against coordinated edits to its own trust root.

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

Version 2 is an **authoritative, in-force Gate 5 integration snapshot** at the current head.
The version 1 historical snapshot remains pinned by its SHA-256. The integration snapshot
binds cohort size, completed decisions, decision yield, unauthorized writes, qualifying
incident IDs, and the complete set of public-safe evidence digests. The gate requires its
`asOfCommit` to equal both the budget and coverage-window head and enforces the staleness
bound while the prerequisite is in force.

Current state: **4 qualifying type-binding integration incidents; trigger fired.**

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
The trigger deliberately counts only budget-eligible incidents that reach shadow or live. Deterministic
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

The initial two-item Gate 5 cohort produced **0 completed decisions — a decision yield of
zero per cent**. One lineage reached real discovery and failed on the empty fingerprint
binding; the other stopped during snapshot finalization. No finding was accepted or
delivered. **Unauthorized writes and total external writes were both zero.**

These facts are recorded in both the observation and authoritative integration snapshot and
are recomputed by the gate. Zero yield and zero writes do not erase the four qualifying
boundary incidents; those incidents are what fire the pre-registered trigger.

The ledger retains the explicit **exposure obligation** from version 1: ten shadow runs by
the twentieth merged coordinator change. The fired trigger no longer waits on that obligation,
but the shortfall remains visible as an implementation-quality requirement and the check
prevents it being quietly declared satisfied.

## Decision status

The conditional decision's prerequisites are satisfied and the trigger is **fired**. The
decision to move the stage control plane to a typed, compiled C# host is therefore recorded
as **taken**. The port itself is **not implemented or complete** by this ledger change.

Each prerequisite is scored on two separate axes, because an artifact that exists is not the
same as a boundary that is protected. **Built** means the artifact and its gate exist and run
in CI. **In force** means production code actually goes through it today.

| Prerequisite | Built | In force | Evidence |
| --- | --- | --- | --- |
| Cardinality and property corpus over the inventoried collection-bearing stage contracts | yes | yes — 236 of 236 rows bound to a shipping producer contract, no gaps; 1120 of 1652 producer-path cells are cardinalities the shipping producer published and the boundary judged (889 census-matched, 231 legitimately reshaped), 472 are boundary refusals of the two shapes a producer must never publish, and 60 are the capture residual | `tools/testdata/reviewer-collection-inventory.v1.json` (236 fields, 12 stages), `src/Agents/reviewer/StageProducers.ps1` (12 boundaries), `tools/Test-ReviewerCollectionCardinality.ps1` (7 variants per field, 11 escape shapes, 9 sabotage checks), `tools/testdata/reviewer-collection-cardinality-matrix.v1.json` |
| Versioned file contract for stage child outputs | yes | partly — the in-memory half is in force (all 12 stage kinds registered in production code, each validated by its own producer before publication); the on-disk half is **not** in force, because no shipping path writes or reads a versioned envelope today | `src/Agents/reviewer/StageContract.ps1`, `src/Agents/reviewer/StageProducers.ps1`, `src/Agents/reviewer/schemas/reviewer.stage-envelope.v1.json`, `src/Agents/reviewer/schemas/reviewer.stage-producer-contracts.v1.json`, `tools/Test-ReviewerStageContract.ps1`, `tools/Test-ReviewerStageProducerContract.ps1` |
| Boundary hardening analyzer with a blocking new-violation gate | yes | yes — every push is scanned and any new violation fails CI | `tools/Find-PowerShellEmptyNullHazard.ps1` (11 rules), `tools/Test-PowerShellBoundaryHardening.ps1`, `tools/testdata/powershell-boundary-baseline.v1.json` |
| Escape ledger and budget with a registered trigger | yes | yes — authoritative Gate 5 integration snapshot, current-head staleness, recomputed counts, fired trigger | this document, `docs/escape-ledger.v2.json`, `tools/Test-EscapeLedger.ps1` |

The corpus is in force at all twelve stage producer boundaries, and it is scored on what
those boundaries actually judged rather than on the fact that a validator returned. Every
shipping producer validates its own output shape against its registered contract before any
consumer sees it, every inventoried field is bound to that contract, and no cell is a gap.
The residuals are recorded rather than rounded away. Of the 1652 producer-path cells, 1120
are cardinalities the producing function published and the boundary judged; 472 are the
null-vs-missing and wrong-scalar variants, whose evidence is refusal by name and which are
therefore not counted as producer-published cardinalities; and 60 belong to the capture
producer, which authenticates a sealed on-disk transcript package that only a live
acquisition can mint. 230 of 236 rows are covered through their stage boundary rather than
their own named call site, and 112 rows name a producer that nothing in `src/` calls today.

The versioned file contract is a different story and is described as one. Its in-memory half
is adopted; its on-disk half is not. No coordinator artifact is written through the atomic
versioned writer or read back through the strict reader on any shipping path, so no consumer
has yet seen a `kind` or a `contractVersion` on disk, and the entry stays not-in-force until
one does. None of this changes the integration result: the fired trigger still makes the C#
control-plane pivot mandatory, and the port itself remains explicitly outstanding.

## Adding an incident

1. Append a historical containment escape to `incidents`, or post-snapshot operational
   evidence to `integrationIncidents`, in `docs/escape-ledger.v2.json`, using the next
   contiguous identifier.
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
