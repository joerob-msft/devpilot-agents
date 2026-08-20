# What the hardening layer does not prove

The four prerequisites in this change — the
[cardinality corpus](collection-cardinality-corpus.md), the
[stage file contract](stage-file-contract.md), the
[boundary analyzer](empty-null-static-analysis.md), and the
[escape ledger](escape-ledger.md) — each publish machine-readable results, and each of those
results is narrower than the phrase describing it would suggest. This page states the gap in
one place so a reader deciding the conditional typed control-plane pivot is not obliged to
reconstruct it from four separate documents.

The short version: fourteen green self-authored gates prove *internal consistency*. They do
not prove completeness, and the difference is exactly the thing the pivot decision turns on.

## Every claim has a named negative control

No gate here asserts only that correct input passes. Each one also asserts that a specific
wrong input fails:

| Claim | Negative control |
| --- | --- |
| The cardinality corpus exercises boundary variants | Nine sabotage checks introduce a known collapse and require the detector to fire |
| Inventory citations are live | Three sabotage checks corrupt a citation's file, leaf token, and container name |
| The stage contract fails closed | Truncated, empty, scalar-collapsed, stdout-contaminated, and unknown-field payloads each have a rejection test |
| Analyzer rules detect their hazard | Every rule has a positive fixture; every rule has a negative fixture proving it ignores the corrected form |
| A test stub cannot silence a rule | A cross-file gate builds a producer, a consumer, and a same-named unprotected mock and requires identical `PSEN011` findings with and without the mock; reverting the fix makes it fail |
| The coverage clock is derived, not asserted | The sabotage checks re-run the real derivation on a mutated ledger, with a positive control on the unmutated one |
| Reclassifying a merged escape out of the budget is visible | Version 2 pins every historical ID, list membership, category, execution stage, and `introducedCommit` in `classificationBaseline`, digest-bound to version 1. Under commit verification, the gate recomputes the retained frozen v1 artifact's digest and derives the baseline comparison from its parsed records. Rewriting a pinned field or moving an escape to `nearMisses` fails the production validator and sabotage controls. The baseline remains a reviewed trust anchor, not external proof of historical causality |
| The clock cannot be switched on by asserting an authority | Setting `inForce: true` fails; so does naming an authority the schema version does not define, which is checked separately from the in-force flag |
| The near-miss baseline is load-bearing | Each near miss's introducing commit is required to be reachable from `HEAD` yet unreachable from its own `classifiedAgainstCommit`, so a baseline that distinguished nothing would fail |
| The baseline cannot be chosen | The baseline is frozen, not chosen: `classifiedAgainstCommit` must equal the version 1 snapshot's pinned classification anchor, and `detectedOn` may not precede the introducing commit's day. A near miss reachable from the current window is accepted only when its ID is preserved by the digest-verified v1 artifact; a newly filed current-window finding must be an escape. Controls run the production validator against the window's start commit, against a commit sharing the detection date, against a backdated `detectedOn`, and against a new near miss already present in the current window. |
| Validator verdicts cannot be discarded silently | Entry counts detect deleted calls, calls sit inside their assertions, and the gate parses its own AST to require each shared validator inside the first `Assert-Ledger` argument. A sabotage copy adds `-or $true` and must fail |
| The ancestry rule cannot be opted out of | `introducedCommit` is required by the schema on both lists and its absence is a gate failure, so a finding cannot leave the git check by dropping a field |
| `category` cannot be edited alone, in either direction | Reclassifying a type-binding escape as `logic` contradicts the collection-collapse detector it cites; classifying an escape into a counted category with no detector implying it fails too, and a control asserts the unanchored escape is the one that would be inflated |
| De-anchoring an escape is visible, not free | The set of findings whose detector implies no category must equal the ledger's declared `categoryAnchorExceptions`, and each entry pins the category the escape is filed under. Rewriting a detector to escape the anchor therefore requires a matching edit to a reviewed list with a written rationale. It is *not* prevented: an author who rewrites the detector, moves the category to an uncounted one, and declares the exception passes every check, and the published count falls by one. What the gate buys is that the change is three coordinated edits in a reviewed list rather than one silent field |
| Debt cannot be closed by relabelling it | A finding marked `accepted` must record an `acceptanceRationale` and an `acceptedOnCommit` that is reachable from the window end, descends from the finding's own `introducedCommit`, and is not dated before `detectedOn` — a risk cannot be accepted at a point in the history before the defect existed. A control flips the real open-debt finding to `accepted`, and a second control accepts it at the commit that introduced it |
| A control cannot outlive the rule it tests | Each rule is one validator called by both the production loop and its control; entry counts catch deleted calls; direct-consumption AST checks catch the known constant-verdict discard. This remains self-checking code, not an independent proof against coordinated edits to the gate and its controls |
| A runtime exposure cannot be hidden by one field | `executionStage` and `reachedShadowOrLive` are checked as equivalent on both lists, and a control mutates a real near miss to shadow and requires the check to reject it |
| The budget would fire | Sabotaged ledger copies with qualifying escapes are required to trigger it |

A gate without a negative control proves that its own happy path still runs. That is worth
little, and none of the counts below rest on one. Three checks in an earlier round of this
change *were* of that kind — one structurally always true, two tautological — and are
recorded as `NM-0002` rather than quietly repaired, because "the negative control was not
negative" is the failure mode this whole page is about.

One classification is checked against git, but git contradicts it rather than establishing
it. Whether a defect is an escape or a near miss decides what the budget counts, so it
cannot rest on an author's boolean: under `-VerifyCommits`, an escape's `introducedCommit`
must be reachable from the coverage window's end commit, and a near miss's must not be
reachable from the fixed `classifiedAgainstCommit` it was filed against. Reclassifying a
merged escape into `nearMisses` fails on that ancestry, not on its prose.

Four residuals are named rather than closed.

- **Reachability is not presence.** That a commit is in a history does not establish that the
  defective state entered an integrated coordinator revision before it was detected. A squash
  or cherry-pick lands the same defect under a different hash, so a real escape can look
  unmerged. A non-squash merge of a branch that both introduced and fixed a defect makes both
  commits reachable, so a genuine near miss can look merged. A defect on an operational side
  branch is reachable from neither. An ancestry *failure* is therefore proof of a misfiling;
  an ancestry *pass* leaves the classification resting on the recorded rationale. Closing this
  properly needs a recorded integration revision in which the defect was actually present,
  checked against named operational refs — deferred, not done.
- **The baseline is frozen, and what is left authored is the date.** `classifiedAgainstCommit`
  is pinned so that merging a change cannot retroactively reclassify the near misses it
  contains, but the pin was originally chosen by the author. Requiring only that it sit on the
  mainline bounded nothing — every commit in the window satisfies that — and a lower bound on
  its date bounded almost nothing, because every non-tip commit sharing a calendar day with
  `detectedOn` still qualified, and there were four. Either form left the escape-to-near-miss
  reclassification available at a cost of one field value, through the field meant to close it.
  Deriving the baseline instead — the mainline as of `detectedOn`, a single commit — collapsed
  the author's choice to nothing but introduced a worse defect: the derivation reads the window
  end, so advancing the window to a later commit on the same day silently moved the expected
  baseline and false-failed both honestly filed near misses. A rule whose verdict on unchanged
  data changes when unrelated history is appended is not an anchor. What replaced it treats the
  ledger as what it is — a frozen historical snapshot: `classifiedAgainstCommit` must equal the
  coverage window's own pinned `endCommit`, so the baseline is not chosen at all, and advancing
  the window authors a *new* snapshot in which the near misses are re-judged rather than editing
  this one. `detectedOn` is bounded in turn: it may not precede the day of the finding's own
  `introducedCommit`, because a defect cannot be detected before the change that introduced it
  exists. What remains authored is `detectedOn` within that bound, and the window end itself —
  which is the assertion the whole snapshot rests on, and which Gate 5 is expected to replace
  with an integration-time record.
- **The classification baseline is an integrity anchor, not historical proof.** Version 2
  closes the silent edit by pinning every historical ID, list, category, and introducing
  commit to the digest-bound version 1 snapshot. That makes any reclassification a visible,
  failing validation. It still does not prove that version 1 named the causally correct commit;
  ancestry proves position in history, not defect presence.
- **`category` is an internal consistency constraint, not corroboration.** What a defect "was"
  is a judgement. The gate holds the category consistent with the detector the incident cites
  — a collection-collapse rule (`PSEN004`/`PSEN005`/`PSEN009`/`PSEN011`, or the cardinality
  boundary harness) implies `typeBinding`, a control-flow rule
  (`PSEN001`/`PSEN002`/`PSEN003`/`PSEN006`/`PSEN010`) implies `logic` — in both directions: a
  detector that implies a category constrains the category, *and* a category the budget counts
  may not be asserted without a detector that implies it. The one-directional form left the
  inflating edit open, because the single escape the anchor cannot reach had a free category
  and the trigger counts `typeBinding`. De-anchoring is now a visible edit rather than a
  prevented one: the set of findings whose detector implies nothing must equal
  `categoryAnchorExceptions` in the ledger, and each entry pins the category the escape is
  filed under. An author who rewrites a detector to name nothing recognised, moves the
  category to one the budget does not count, and declares the exception still passes every
  check, and the published count still falls by one — the cost is three coordinated edits to a
  reviewed list carrying a written rationale, not a single silent field. That is the limit of
  what this anchor can do, because **both fields are authored**, and detector family does not
  establish root cause. `PSEN007` and `PSEN008` are serialization rules that legitimately
  imply neither family, and a detector naming both families implies nothing; either case is an
  exception that must be declared. Eleven of twelve escapes are consistent this way, reported
  as `categoryDetectorConsistent`; `ESC-0011` is a supervision finding detected by review, with
  no detector to check against. That count is deliberately not offered as assurance evidence.
- **A control that restates a rule is not a control, and a control that outlives its call site
  is not one either.** Every sabotage check in this gate calls the same validator the production
  loop calls, on a freshly parsed copy of the real ledger. The earlier form asserted the rule's
  predicate a second time inside the control, which meant the control stayed green when the
  production assertion was deleted — verified by replacing two real assertions with
  unconditional success and watching all checks still pass. Three further controls added while
  closing that were themselves structurally unfalsifiable, which is the same defect recorded as
  `NM-0002`. Extracting each rule into a shared validator fixed the body but not the call: a
  control invokes the validator directly, so it cannot see whether production still does, and
  replacing any of four production assertions with unconditional success left the gate green
  *without even moving the check count*. Each validator therefore records its entry, and the
  expected entry count — production invocations plus the fixed number of control invocations —
  is asserted near the report, so a deleted call fails a check no control can supply. Counting
  entries alone was still not enough, because six of the seven sites called the validator on
  one line and asserted its result on the next: neutering the assertion left the call, and so
  the count, intact. Each call is now written *inside* the assertion it feeds, so the two cannot
  be separated by a one-line edit. Verified at all seven sites in both forms. Two residuals
  remain, and neither is closed: an edit that deliberately keeps the call and discards its
  verdict — `Assert-Ledger ((Get-…Objection …) -ne $null -or $true)` — still disables the rule
  while satisfying the counter, and the expected counts are hand-maintained, so adding a control
  requires updating a number (the failure message says so). The unfalsifiable-control shape
  itself is still not detected automatically; it is caught only by neutering a rule and
  confirming its control fails.
- **The check needs git and the switch.** It only runs under `-VerifyCommits`; a schema-only
  validation still sees the booleans as authored. CI runs it with `fetch-depth: 0`, so every
  push gets the ancestry rules, but a local run without the switch does not.
- **The clock is hand-maintained.** See below.

Because reachability cannot settle it, the near-miss category is not allowed to swallow
runtime evidence. `reachedShadowOrLive` is deliberately *not* pinned false for near misses:
a defect can reach shadow or live execution without ever merging, and a taxonomy that could
not express that would drop the strongest available evidence for the typed-host decision on
a technicality. Containment escapes and runtime exposure findings are counted on separate
axes and both are published; only the first is budget evidence.

## Known false negatives are fixed; blind spots are not

Within the syntax each analyzer rule states it inspects, the false negatives found by review
are fixed and pinned by fixtures — including the three that failed open in this change and
are recorded as `NM-0001`. Outside that syntax, the rules are blind, and no fixture makes
them otherwise:

- **Dynamic invocation.** `&$name`, `Invoke-Expression`, and command names built at runtime
  are not resolved, so a collection crossing a boundary through one is not seen.
- **Module and dot-source boundaries.** Name resolution is textual and repository-scoped. A
  function reached through an imported module is not analyzed.
- **Type flow.** The analyzer reasons about syntactic shape, not types. A variable that
  holds a collection only on some paths is judged by how it is written, not what it holds.
- **Producer paths.** The corpus drives variants through the registered contract each stage
  publishes through, and through the shipping producer function itself wherever that function
  runs without a live capture or a model. The score is read back out of the contract ledger,
  which records the element count the boundary actually judged, so a cell states what was
  published rather than that a validator returned: of 1652 producer cells, 1120 are
  cardinalities the producing function published (1009 matching the constructed count, 111
  legitimately reshaped by deduplication or union), 472 are refusals of the null-vs-missing
  and wrong-scalar shapes and are not counted as published cardinalities, 60 belong to the
  capture stage, and 0 remain gaps. What it still does not do is execute a stage end to end
  against a real repository, so 230 of the 236 rows are covered through their stage boundary
  rather than their own call site, and 112 rows name a producer that nothing in `src/` calls
  today.

## No completeness, precision, or recall claim

- The inventory is **hand-curated**. 236 rows were found by reading the pipeline; nothing
  proves a 237th does not exist. The matrix publishes `fullCoverageClaimed: false` and the
  gate refuses to set it true.
- Of 419 citations, **258 are leaf-verified and 161 are not** — the unverified ones name a
  bare `$variable` with no leaf token to match. Both counts are published separately rather
  than summed into a single reassuring number.
- Fixture scores (15 TP / 0 FP / 0 FN / 12 TN) are **scores on the fixture set**, not
  precision and recall on this repository. They say the rules behave as labeled on cases
  chosen to characterize them.
- **The in-force clock is authoritative only for the pinned Gate 5 snapshot.** Version 2
  binds the current head, cohort cardinality, zero decision yield, zero unauthorized writes,
  qualifying incident IDs, and evidence digests. CI requires the budget, coverage window, and
  snapshot commits to agree and enforces staleness while `inForce`. Future coordinator changes
  still require advancing the snapshot; this is not a general coordinator-change registry.

## Built here versus adopted

Everything in this change is **built here** and reviewed here. None of it is an adopted
third-party analyzer with an independent user base finding its bugs. The three fail-open
holes in `NM-0001`, and the three unfalsifiable checks in `NM-0002` that the fix for
`NM-0001` introduced, were both found by review of this change rather than by the tooling's
own tests — which is the strongest available evidence that self-authored verification needs
external scrutiny, and the reason this page exists.

## Deliberately deferred

- **Shadow exposure.** Nothing here runs a model or writes to an external system. The
  no-write invariant is asserted, not relaxed.
- **Producer-path coverage.** The remaining increment is narrower than it was, and named
  precisely: 60 cells on the capture stage need a live acquisition to mint a sealed package,
  111 cells are reshaped rather than passed through, 230 rows are covered through their stage
  boundary rather than their own call site, and 112 rows name a producer with no caller in
  `src/` today.
- **On-disk file contract.** The versioned envelope is still test-only. No shipping path
  writes or reads one, so no consumer has yet seen a `kind` or a `contractVersion` on disk.
- **Historical replay of sabotage.** Sabotage proves the detector recognises the escape
  *shape* as re-authored here, not that it would have fired on the original source.
- **Behaviour-versus-build-identity hashing.** The exact-path oracle hash still mixes both,
  so a build-only change re-blesses it. Splitting the two is correct and out of scope for a
  prerequisite change.
