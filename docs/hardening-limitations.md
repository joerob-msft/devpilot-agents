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
| A merged escape cannot be reclassified out of the budget | Moving a merged incident into `nearMisses` fails the git ancestry check, with both directions probed against real cited commits |
| The budget would fire | Sabotaged ledger copies with qualifying escapes are required to trigger it |

A gate without a negative control proves that its own happy path still runs. That is worth
little, and none of the counts below rest on one. Three checks in an earlier round of this
change *were* of that kind — one structurally always true, two tautological — and are
recorded as `NM-0002` rather than quietly repaired, because "the negative control was not
negative" is the failure mode this whole page is about.

One classification is checked against git rather than against itself. Whether a defect is
an escape or a near miss decides what the budget counts, so it cannot rest on an author's
boolean: under `-VerifyCommits`, an escape's `introducedCommit` must be reachable from the
coverage window's end commit and a near miss's must not. Reclassifying a merged escape into
`nearMisses` fails on that ancestry, not on its prose. The residual limitation is that this
check needs git and only runs under `-VerifyCommits`; a schema-only validation still sees
the booleans as authored.

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
- **Producer paths.** The corpus drives variants through the shared contract. It does not
  execute the production writers, so the matrix publishes 1652 producer gaps against 0
  boundary gaps, and that ratio is the honest summary of its reach.

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
- **The escape ledger's budget clock is not authoritative, and its lag is not bounded.**
  "Coordinator changes" are not derivable from git history here, so
  `coordinatorChangesObserved` advances only when an incident carries a higher ordinal. An
  incident-free coordinator change — the common case — does not move it, and `evaluatedOn`
  tracks the newest incident rather than the present, so the ledger has no valid refresh
  after a quiet period. Commits-per-change bounds *staleness of the end commit*; it does
  not bound how far the change ordinal can drift, because forty commits may contain zero
  coordinator changes or forty. The ordinals are authored, so the honest statement is that
  the clock is **hand-maintained**, not that it lags predictably. The budget is therefore
  recorded as **built but not in force**, and the gate refuses to let it be declared in
  force while `clockAuthority` is `authoredOrdinals`. Gate 5 must supply an authoritative
  current ordinal and date rather than reading this clock as current.

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
- **Producer-path coverage.** Driving variants through the real writers is the next
  increment; the 1652 producer gaps name it precisely.
- **Historical replay of sabotage.** Sabotage proves the detector recognises the escape
  *shape* as re-authored here, not that it would have fired on the original source.
- **Behaviour-versus-build-identity hashing.** The exact-path oracle hash still mixes both,
  so a build-only change re-blesses it. Splitting the two is correct and out of scope for a
  prerequisite change.
