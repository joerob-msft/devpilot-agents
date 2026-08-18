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
| A merged escape cannot be reclassified out of the budget | Moving a merged incident into `nearMisses` fails the git ancestry check, with both directions probed against real cited commits, and choosing an older baseline to evade that fails the baseline-currency rules |
| The clock cannot be switched on by asserting an authority | Setting `inForce: true` fails; so does naming an authority the schema version does not define, which is checked separately from the in-force flag |
| The near-miss baseline is load-bearing | Each near miss's introducing commit is required to be reachable from `HEAD` yet unreachable from its own `classifiedAgainstCommit`, so a baseline that distinguished nothing would fail |
| The baseline cannot be backdated | A baseline may not predate the finding's `detectedOn`, and every escape introduced before that date must be reachable from it; a control proves both rules reject the coverage window's own start commit |
| The ancestry rule cannot be opted out of | `introducedCommit` is required by the schema on both lists and its absence is a gate failure, so a finding cannot leave the git check by dropping a field |
| `category` cannot be edited alone, in either direction | Reclassifying a type-binding escape as `logic` contradicts the collection-collapse detector it cites; classifying an escape into a counted category with no detector implying it fails too, and a control asserts the unanchored escape is the one that would be inflated |
| An escape cannot be freed by de-anchoring it | The set of findings whose detector implies no category must equal the ledger's declared `categoryAnchorExceptions`, so rewriting a detector to escape the anchor fails rather than lowering a counter |
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
- **The baseline is authored.** `classifiedAgainstCommit` is pinned so that merging a change
  cannot retroactively reclassify the near misses it contains, but the pin itself is chosen by
  the author. Requiring only that it sit on the mainline bounded nothing — every commit in the
  window satisfies that, so naming an old enough baseline restored the escape-to-near-miss
  reclassification through the field meant to close it. It is now held to the claim it makes:
  the baseline's commit date may not precede the finding's `detectedOn`, and every escape the
  ledger records as introduced before that date must be reachable from it. A control proves
  both rules reject the coverage window's own start commit — the most plausible bad baseline,
  since it is on the mainline and old enough to make any escape look unmerged. What remains
  unproven is the exact commit: any commit in the short interval between the last prior escape
  and the detection date satisfies both rules, and `detectedOn` is itself authored.
- **`introducedCommit`'s value is not tied to the defect.** Ancestry checks *where* a commit
  sits, not that it is the right commit. Naming a different real commit on the correct side of
  the boundary passes. The obvious anchor — requiring the introducing commit to touch a file
  the remediating commit also touches — was tried and rejected because it produces a false
  failure on correctly filed data: `ESC-0006`'s defect was remediated in
  `src/Agents/reviewer/SourceTransport.ps1`, a file extracted from
  `Start-ReviewerAgent.ps1` in `b563d1b`, long after the commit that introduced the code. A
  rule needing a per-incident exemption list to stay green is the fail-open shape this page
  exists to name, so the gap is published instead.
- **`category` is an internal consistency constraint, not corroboration.** What a defect "was"
  is a judgement. The gate holds the category consistent with the detector the incident cites
  — a collection-collapse rule (`PSEN004`/`PSEN005`/`PSEN009`/`PSEN011`, or the cardinality
  boundary harness) implies `typeBinding`, a control-flow rule
  (`PSEN001`/`PSEN002`/`PSEN003`/`PSEN006`/`PSEN010`) implies `logic` — in both directions: a
  detector that implies a category constrains the category, *and* a category the budget counts
  may not be asserted without a detector that implies it. The one-directional form left the
  inflating edit open, because the single escape the anchor cannot reach had a free category
  and the trigger counts `typeBinding`. De-anchoring is now itself a visible edit: the set of
  findings whose detector implies nothing must equal `categoryAnchorExceptions` in the ledger,
  so rewriting a detector to escape the anchor fails rather than showing up as a published
  counter falling by one. But **both fields are authored**, and detector family does not
  establish root cause. `PSEN007` and `PSEN008` are serialization rules that legitimately
  imply neither family, and a detector naming both families implies nothing; either case is an
  exception that must be declared. Eleven of twelve escapes are consistent this way, reported
  as `categoryDetectorConsistent`; `ESC-0011` is a supervision finding detected by review, with
  no detector to check against. That count is deliberately not offered as assurance evidence.
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
  force while `clockAuthority` is `authoredOrdinals`. Only that one authority is defined in
  this schema version, deliberately: an earlier form of the rule accepted any other authority
  and blessed the in-force claim on sight, so two string edits — name a registry that does not
  exist, set the flag — produced a green but still authority-free clock. A new authority may
  be named only in the change that also adds the data it reads and the checks that establish
  that data is current. The counts themselves carry `operationalStatus: historicalSnapshot`
  and `asOfCommit` in the machine-readable budget, so a parser cannot lift them without the
  caveat. Gate 5 must supply an authoritative current ordinal and date rather than reading
  this clock as current. The trigger is nonetheless pre-registered rather than deferred,
  because fixing a threshold before any run exists to read is what stops it moving after
  results are seen.

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
