# Collection cardinality corpus

Every escape in the type-binding category of the [escape ledger](escape-ledger.md) has the
same shape: a collection with zero or one element crossed a boundary and arrived as
something else. The corpus exists so that shape is exercised everywhere it can occur, rather
than wherever somebody remembered to write a test.

## Inventory

`tools/testdata/reviewer-collection-inventory.v1.json` inventories every collection-bearing
field in the reviewer's stage contracts — **236 fields across twelve stages**, in pipeline
order:

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

## Variants

`tools/Test-ReviewerCollectionCardinality.ps1` drives every inventoried field through seven
cardinality variants:

| Variant | Value produced | Must arrive as |
|---|---|---|
| `zero` | empty collection | 0 elements |
| `one` | single element | 1 element |
| `many` | three elements | 3 elements |
| `max` | the declared maximum | that many elements |
| `duplicate` | repeated elements | all of them, duplicates intact |
| `nullVsMissing` | `$null` where the field is declared | 0 elements, distinguishable from absent |
| `wrongScalar` | a bare scalar where a collection is declared | 1 element |

That is **1,652 boundary cases**, each written through the stage contract, serialized, read
back, and counted.

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
escape?* Each historical collapse in the ledger has a sabotage check that reproduces it.

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
| `boundaryNormalizer` | 1652 | 0 | The variant was written, serialized, read back, and counted through the shared contract |
| `producerPath` | 0 | 1652 | The variant was produced by the real stage that owns the field |

`producerPath` is zero for every field, and the matrix says so. The corpus is deliberately
employer-neutral and runs no stage: it proves the boundary machinery handles every declared
shape, not that each stage actually emits those shapes. Closing that dimension requires
running the stages, which requires models, which this layer excludes.

`fullCoverageClaimed` is therefore `false`, and the check enforces it mechanically: full
coverage may only be claimed when every inventoried field has every required variant in
*both* dimensions. A matrix that claimed otherwise would fail its own test.
