# Collection cardinality corpus

Every escape in the type-binding category of the [escape ledger](escape-ledger.md) has the
same shape: a collection with zero or one element crossed a boundary and arrived as
something else. The corpus exists so that shape is exercised for every inventoried row
through the shared contract, rather than wherever somebody remembered to write a test. What
it does *not* do is exercise the production writer, or prove the inventory complete; both
limitations are stated plainly below and published in the matrix.


> **Scope.** What this does *not* prove is stated in
> [what the hardening layer does not prove](hardening-limitations.md).

## Inventory

`tools/testdata/reviewer-collection-inventory.v1.json` is a hand-curated inventory of the
collection-bearing fields in the reviewer's stage contracts — **236 fields across twelve
stages**, in pipeline order:

| Stage | Fields | | Stage | Fields |
|---|---:|---|---|---:|
| capture | 12 | | fingerprints | 8 |
| source | 24 | | specialistPlan | 30 |
| snapshot | 29 | | verifierAssignment | 15 |
| corpus | 8 | | verdict | 10 |
| blindResults | 23 | | reconciliation | 30 |
| candidateUnion | 20 | | deliveryDecision | 27 |

Each row records the stage, the contract, the field path, its kind (`jsonArray`,
`jsonObjectMap`, `list`, `hashSet`, or `psCollectionReturn`), whether it is required, its
producer and consumer, the way it could collapse, and whether it is a *known escape shape* —
a field whose collapse has actually happened. Fifteen rows carry that flag, including the
empty `HashSet` return, empty and singleton arrays, `evidenceFactIds`, configuration
singleton and empty arrays, empty exact-key differences, `ExistingFingerprints`, and the
source readers.

Field kinds distinguish what can go wrong. A `jsonArray` collapses on serialization; a
`hashSet` collapses on return; a `psCollectionReturn` collapses on assignment. The variant
generator produces a different hazardous value for each.

The inventory was built by reading the pipeline stage by stage, so its **completeness is
unverified**: nothing in this repository proves that a collection-bearing field cannot exist
without a row here. The [citation liveness](#citation-liveness) check keeps the rows that do
exist honest; it cannot vouch for the ones that were never written.

## Variants

`tools/Test-ReviewerCollectionCardinality.ps1` drives every inventoried field through seven
cardinality variants:

| Variant | Value produced | Must arrive as |
|---|---|---|
| `zero` | empty collection | 0 elements |
| `one` | single element | 1 element |
| `many` | three elements | 3 elements |
| `max` | a fixed upper-bound sample of 32 elements | 32 elements |
| `duplicate` | repeated elements | all of them, duplicates intact |
| `nullVsMissing` | `$null` where the field is declared | 0 elements, distinguishable from absent |
| `wrongScalar` | a bare scalar where a collection is declared | 1 element |

That is **1,652 boundary cases**, each written through the stage contract, serialized, read
back, and counted.

## What a boundary case actually exercises

Each case drives one inventoried field's declared *kind* and *cardinality* through the
shared contract using a neutral probe payload. It does **not** invoke the stage that owns
the field, and it does not use the field's own name, declared maximum, or producer. The
inventory row supplies the field kind and the variant set; the rest of the row — producer,
consumer, contract, required-ness — is inventory metadata, not test input.

Two consequences follow, and neither is hidden by the matrix:

* `max` is a fixed 32-element sample, not a per-field declared maximum. No stage contract in
  this repository declares a maximum element count, so there is nothing to read; 32 is
  chosen to exceed every cardinality the corpus otherwise exercises.
* `wrongScalar` passes because the contract writer repairs an unrolled singleton, which is
  the behaviour under test. The producer-side question — whether the stage should have
  emitted a scalar at all — is answered by `-StrictShape`, which reports the collapse
  instead of repairing it, not by this variant.

This is why the matrix keeps `producerPath` as a separate dimension rather than folding it
into a single coverage number: the two answer different questions, and only one of them can
be answered without running the stage that owns the field.

## Maps are not arrays

Five inventoried fields are JSON objects used as maps, and they collapse differently. An
empty map must serialize as `{}` and not `[]`; a one-key map must not read back as its
single value; and a scalar where a map was declared has no meaningful repair, because a map
has keys and a scalar has none, so the only correct answer is to refuse it. The `duplicate`
variant for a map is duplicate *values* under distinct keys, since a map cannot carry a
duplicate key at all.

Those rows are judged by the stage contract's map validator rather than its list normalizer,
and the matrix records which validator ran per row in `boundaryValidator`. A map is validated
and never repaired: there is no correct rewrite from an array or a scalar to a keyed object.
Driving them as arrays would have reported seven covered variants each while testing none of
the failures that actually apply to them.

## Escape-shape properties

Eleven property tests assert both halves of a collapse: that the unguarded form *does*
collapse, and that the guarded form does not. A property test whose unguarded half stops
collapsing fails — it would otherwise keep passing while proving nothing.

The shapes are: the bare empty set return, the bare singleton set return, `@()` around a
protected return, `@()` around an empty protected return, a JSON document whose root is an
array, an empty `Where-Object` difference, a singleton difference, configuration array round
trips, empty `ExistingFingerprints`, source-reader cardinality, and the stage contract's own
null-versus-missing handling.

The deliberately hazardous producers live in
`tools/testdata/collection-escape-shapes.fixtures.ps1` so that the test itself can stay
clean under the boundary analyzer.

## Sabotage

Nine sabotage checks introduce a known collapse into a temporary copy of otherwise-correct
code and assert that the detector fires. Eight target the analyzer rules `PSEN004` through
`PSEN011`; the ninth feeds a scalar-collapsed payload to the stage contract reader and
asserts it fails closed.

Sabotage answers the question a passing test suite cannot: *would this have caught the
escape?* Each of the eight analyzer-detectable collapse shapes in the ledger has a sabotage
check that reproduces it. `NM-0001` — the round where the detectors themselves failed open —
is guarded by fixtures and cross-file tests in the boundary suite rather than by a sabotage
check here.

The claim is bounded: a sabotage check proves the detector recognises the escape *shape* as
re-authored here, not that it would have fired on the exact historical source. Proving the
stronger claim means running the analyzer against the pre-fix snapshots themselves, which
is left as a follow-up rather than asserted here.

## Citation liveness

An inventory is only useful while its citations are true. Every row names a producer and a
consumer, and the check resolves each cited file against the repository and confirms the
file still mentions the field. 419 citations are checked, of which 258 are leaf-verified. A
row that cites a deleted file, a bare file name that now matches more than one file, or a
file that no longer mentions the field fails the build.

The token that must be present is the **leaf** of the path, not any segment of it — the last
segment of `$.selectedPacks[*].matchedPaths` is `matchedPaths`, not `selectedPacks`.
Accepting any segment made the check vacuous for nested paths: a citation pointing at the
wrong file passes whenever that file happens to mention the generic container name, so a
renamed or miscited leaf — the thing the row is actually about — stayed invisible. Five live
citations were wrong under the weaker rule and are corrected here; a sabotage check pins the
container-is-not-the-leaf distinction so the hole cannot reopen. Both path notations in use
are handled, JSONPath (`$.a.b[*].c`) and JSON pointer (`/a/b[*]/c`), and no minimum token
length is applied, because short leaf names like `ids` and `sha` are exactly the ones a
length filter would silently drop.

Two exemptions are deliberate and narrow. A quoted literal inside a citation is data the
cited code contains, not a second citation. And a row whose field is a producer-local
PowerShell variable rather than a serialized field has no leaf to require — the consuming
file knows that value by its own parameter name — so it gets the file-existence check only.
Those 161 rows are published as `citationsUnverified` rather than folded into the verified
count, because a check that silently skips is a check that overstates itself.

The check has its own sabotage checks: a citation of a nonexistent file must fail to
resolve, a bare name that exists exactly once must resolve, a field name that appears
nowhere must be reported as absent, a nested path must yield its leaf and not its container,
a short leaf must be required rather than dropped, and a prose qualifier after a path must
not be mistaken for a field name. A liveness check that reports nothing is otherwise
indistinguishable from one that is broken.

**What this does not do.** It is a liveness check on existing rows, not a completeness
check on the inventory. It cannot see a newly added collection field that was never
inventoried, it does not verify that the cited file still *owns* the field rather than
merely mentioning it, and it does not detect a row whose `kind` has drifted. A token match
is a weak witness on purpose: it is case-insensitive, because PowerShell property access is,
and it accepts the leaf anywhere in the file. The inventory therefore remains
hand-curated and its completeness is unverified. Establishing completeness would require
generating rows from schema and contract registrations, or a two-way scan that fails on a
collection declaration with no inventory row; neither is attempted here.

## Coverage matrix, and what it does not claim

`tools/testdata/reviewer-collection-cardinality-matrix.v1.json` is derived from the run and
byte-compared against the checked-in copy, so it cannot drift from reality. Regenerate it
deliberately:

```powershell
./tools/Test-ReviewerCollectionCardinality.ps1 -UpdateMatrix
```

The matrix records **two coverage dimensions that are never merged**:

| Dimension | Covered | Gaps | Meaning |
|---|---:|---:|---|
| `boundaryNormalizer` | 1652 | 0 | The variant was written, serialized, read back, and counted through the shared contract — by the list validator for `collectionShape` rows and by the map validator for `mapShape` rows, as recorded per row in `boundaryValidator` |
| `producerPath` | 1120 producer-published + 472 boundaryRefusal + 60 boundaryOnly | 0 | The variant was pushed through the registered contract its stage publishes through — via the production builder in `src/Agents/reviewer/StageProducers.ps1` — and, for every stage whose producer runs without a live capture or a model, through the shipping producer function itself |

`producerPath` is evidence of execution, and the evidence is the census, not the call. Every
assertion records the element count the boundary judged for each declared collection field,
and the cell is classified from that count, so "a validator returned successfully" is never
enough on its own. Deleting a producer's validation call turns the cell into a gap rather
than leaving it green.

| Status | Cells | Meaning |
|---|---:|---|
| `producerCensusMatched` | 1009 | The shipping producer ran and the boundary judged a census whose element count equals the cardinality the harness constructed |
| `producerCensusReshaped` | 111 | The shipping producer ran and the boundary judged its census, but the count differs because the producer legitimately deduplicates, unions, or folds; `producerObservedCensus` records what the boundary saw |
| `boundaryRefusal` | 472 | Not a census: the null-vs-missing and wrong-scalar variants are shapes a producer must never publish, and the evidence is the boundary refusing them **by name** before any consumer runs |
| `boundaryOnly` | 60 | The registered boundary ran through the production builder, but the producing function needs a live capture |
| `gap` | 0 | Neither ran |

The refusal cells are deliberately not folded into the producer-published total. Refusing a
collapse and publishing a census are different facts, and a summary that added them together
would claim 1592 producer-driven cardinalities where only 1120 exist.

Four residuals are published rather than rounded away:

- **`boundaryOnly` (60 cells).** The capture stage's producer authenticates a sealed on-disk
  transcript package that only a live acquisition can mint. Its twelve rows are driven
  through the same registered boundary the producer calls, but not through the producer
  itself, and `producerResidual` on those rows says so.
- **`stageBoundaryEquivalent` (230 of 236 rows).** Most inventoried fields are internal
  collections inside a stage rather than the stage's published census. They are covered
  through the boundary their stage publishes through — production-equivalent, and driven by
  production code — but not through their own call site. Only 6 rows are `direct`.
- **Test-only reach (112 rows).** `producerProductionReachable` is scanned, not asserted: a
  producer that nothing under `src/` calls today is in force where it stands, but it is not
  yet on a live coordinator path. `producerProductionCallers` lists the shipping files that
  do call it.
- **Census, not pipeline unrolling.** `producerCensusMatched` is evidence about what the
  boundary judged, which is where the collapse this corpus exists to catch happens. It is not
  a claim about what PowerShell's pipeline does to the producer's `return` statement: a
  function returning an array still unrolls, so a caller that assigns without `@()` sees
  `$null` for zero elements and a scalar for one. That is unchanged from the base commit,
  is what the repository's own `PSEN004` debt of 0 records as materialized, and is handled
  at the call sites. Closing it would mean rewriting the return convention of every producer,
  which this change deliberately does not do.

Because these residuals are non-zero, `fullCoverageClaimed` stays `false`. The corpus is still
employer-neutral: every producer above is called with synthetic, production-shaped input, and
no model, session, or external write is involved.

Closing that dimension does **not** uniformly require models, and it would be convenient but
untrue to say so. Most of the inventoried boundaries are deterministic — parsers,
serializers, readers, reconcilers, and the consumers that index their results — and can be
driven directly at each cardinality with no model at all. Even the model-facing consumers can
be driven from synthetic response envelopes. What genuinely requires models is only the
representative end-to-end case: proving that the shapes a real model actually produces are
the shapes the corpus assumes. The dimension is open here because driving real stage code is
a larger change than a prerequisite layer should make, not because it is impossible without
models.

`fullCoverageClaimed` is therefore `false`, and the check enforces it mechanically: full
coverage may only be claimed when every inventoried field has every required variant in
*both* dimensions. A matrix that claimed otherwise would fail its own test.
