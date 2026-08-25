# Stage file contract

Coordinator stages hand work to child processes and read the result back. When that result
arrives on standard output, or without a declared version, or with a depth the host chose,
the boundary is where shape is lost: a one-element array reads back as a scalar, an empty
collection reads back as null, and a diagnostic line printed by a well-meaning helper reads
back as part of the contract.

`src/Agents/reviewer/StageContract.ps1` makes that boundary explicit and fails closed.

> **Adoption status: in-memory half in force on the ordinary path; on-disk half built and
> CI-verified but NOT in force — it runs only behind an opt-in switch that nothing under
> `src/` turns on.**
> [`src/Agents/reviewer/StageProducers.ps1`](../src/Agents/reviewer/StageProducers.ps1)
> registers a versioned contract kind for each of twelve enumerated stages —
> capture, source, snapshot, corpus, blindResults, candidateUnion, fingerprints,
> specialistPlan, verifierAssignment, verdict, reconciliation, deliveryDecision — and each
> shipping producer validates its own output against its contract before any consumer or
> any persistence sees it. Removing that call, assigning its verdict to `$null`, or never
> reading the verdict back fails
> [`tools/Test-ReviewerStageProducerContract.ps1`](../tools/Test-ReviewerStageProducerContract.ps1),
> which reads the producer's syntax tree rather than its text.
>
> Note the shape of that claim: the checkers prove every *registered* kind has a producer
> that validates through it. Nothing here proves the registry is *complete* — that the
> twelve are every handoff a coordinator crosses. The twelve are an enumeration adopted by
> hand, and a thirteenth handoff added without a registration would be invisible to these
> suites.
>
> What is validated at those boundaries is the payload *shape* — the same registered kind,
> the same required and unknown field policy, the same collection and map rules. By default
> that verdict is held in memory and nothing is written.
>
> [`src/Agents/reviewer/StageShadow.ps1`](../src/Agents/reviewer/StageShadow.ps1) adds the
> switch that exercises the on-disk half. With it enabled, all twelve boundaries publish
> their judged payload through `Write-ReviewerStageArtifact` under `-StrictShape` and
> immediately read it back through `Read-ReviewerStageArtifact` before the payload goes
> anywhere downstream. The reread verdict is consumed, not logged: the contract version *the
> file itself declares*, adapted-ness, byte digest and length, declared form and depth, and
> the full serialized payload must all agree with what was written, or the boundary throws.
> The reader's registry-held kind and version are deliberately not compared, because those
> are the reader echoing the caller's own request and cannot disagree with themselves. The
> publish path also compares the kind the file declared, but that one is deliberately counted
> as redundancy rather than evidence: `Read-ReviewerStageArtifact` already refuses a kind
> mismatch itself, so with the shipped reader that comparison cannot fail, and it is kept
> only against a future reader that stops refusing. A run with the switch on cannot reach a
> downstream stage with a payload that did not survive a real file round trip.
>
> Three properties keep this safe to ship:
>
> * **Default off.** With the switch disabled, `Publish-ReviewerStageShadowArtifact` returns
>   the very object it was handed and touches no filesystem. Ordinary production behaviour is
>   unchanged.
> * **No semantic change.** What flows downstream is the in-memory payload the boundary
>   already judged, never a JSON reconstruction of it. The reread payload is *evidence* — it
>   must serialize identically to what was written — so no decision is ever taken on a parsed
>   value. Be precise about what that buys: it proves the payload is **serializable and
>   rereadable**, not that the reconstruction is **substitutable** for the original. The
>   comparison is between two serializations, and a serialization is lossy about CLR types —
>   `ConvertFrom-Json` reconstructs an integral JSON number within the `Int64` range as
>   `Int64`, so `Int32` and every narrower integer type returns widened, while one outside
>   that range returns as a `BigInteger`; a non-integral one may return as `Double`, so a
>   `Decimal` loses its type; a `DateTimeOffset` returns as a string or a `DateTime`; and
>   `NaN`/`Infinity` are written and returned as strings. Nothing downstream
>   consumes the reconstruction, so that gap cannot
>   change a decision here; it is a real limit on what a future off-disk consumer may assume.
> * **No external delivery writes.** The switch writes files — that is its purpose — but only
>   private state under a directory it owns. It refuses to open while any delivery capability
>   is live,
>   recomputing that through `Get-ReviewerGateWritesCurrentlyRequested` rather than accepting
>   a caller's verdict — though the policy object it judges is still caller-supplied, so this
>   is a constraint on declared configuration rather than an observation of a live run.
>   Artifacts land only under a directory the switch owns and marks — a marker is a
>   convention anything with write access could forge, so it refuses the accident rather than
>   an adversary. Each artifact is made read-only when published, which is an advisory
>   attribute rather than enforcement; the load-bearing guarantee is that a name collision
>   with existing evidence is refused outright rather than resolved in favour of the newcomer.
>   That refusal is an atomic `CreateNew` reservation on a `.reservation` sidecar rather than a
>   look at the artifact path, so two concurrent publishers cannot both pass and the artifact
>   path itself is never briefly visible as a zero-byte file. The sidecar is kept, not cleaned
>   up: it is what keeps the name unusable, and it is outside the `*.stage.json` inventory.
>   A reused directory seeds its sequence past reserved names as well as published ones, so a
>   publish that reserved a name and then refused its payload cannot brick the directory for
>   later sessions, and a refusal always means a live collision.
>
> Evidence: [`tools/Test-ReviewerStageShadow.ps1`](../tools/Test-ReviewerStageShadow.ps1)
> drives every stage kind at zero, one, many, max, and duplicate through a real file and
> compares the census read back off disk against the census that went in; refuses null and
> wrong-scalar at the boundary with nothing written; runs the BOM, truncation, stdout
> prologue/epilogue, unknown-field, missing-field, foreign-kind, unsupported-version,
> form-disagreement and collapsed-collection fault matrix; and sabotages the publish path
> both statically and dynamically.
> [`tools/Invoke-ReviewerStageShadowRun.ps1`](../tools/Invoke-ReviewerStageShadowRun.ps1)
> produces all twelve stage artifacts in one no-model run.
>
> **Residual: the switch is opt-in, so the on-disk half is exercised only when a caller
> turns it on, and no shipping entry point does.** That is why the escape ledger scores this
> prerequisite's on-disk half as *not* in force and records what it really is under
> `adoptionScope` instead; `tools/Test-EscapeLedger.ps1` fails if that record and `src/`
> disagree in either direction. Migrating the coordinator's ordinary path onto on-disk
> publication changes live behaviour and stays out of scope for a prerequisite change that
> runs no models. Two further residuals: one artifact is not byte-reproducible across
> processes — the capture census is built from a `Hashtable`'s key order, and .NET randomizes
> string hashing per process — so the run report pins a second digest alongside the exact one
> in which two individually named capture fields, `packageFiles` and `packageDirectories`,
> are compared as multisets. On those two fields only, that digest cannot see an ordering
> regression; every other stage and every other field keeps its order in both digests. And
> the run tools themselves are manual evidence recipes whose execution is not CI-verified: CI
> runs the suites that pin the switch's code, but nothing in CI executes either tool and
> neither checks in a report, so their artifact counts and digests are transcriptions of a
> hand-run command.


> **Scope.** What this does *not* prove is stated in
> [what the hardening layer does not prove](hardening-limitations.md).

## The envelope

Every stage artifact is a JSON object with a fixed shape. The shape is documented by
[`reviewer.stage-envelope.v1.json`](../src/Agents/reviewer/schemas/reviewer.stage-envelope.v1.json)
and enforced at runtime by hand-coded checks in `StageContract.ps1` — PowerShell ships no
JSON Schema validator, so the schema is a specification the checks are written against, not
an artifact they execute:

```json
{
  "envelopeVersion": 1,
  "kind": "reviewer.specialist.plan",
  "contractVersion": 2,
  "form": "compact",
  "depth": 12,
  "payload": { }
}
```

`kind` and `contractVersion` are required and are checked against the contract the reader
asks for. `form` and `depth` record the serialization decision that produced the file, so a
reader never has to guess and a diff never silently changes shape. The schema is closed:
an unknown top-level field is a rejection, not a forward-compatible extra.

## Registering a contract

A contract declares its kind, its current version, its collection fields, and any adapters
from older versions:

```powershell
Register-ReviewerStageContract -Kind 'reviewer.specialist.plan' -ContractVersion 2 `
    -CollectionFields @('captureTargets', 'evidenceFactIds', 'notes[*].tags') `
    -MapFields @('countsByPath') `
    -RequiredFields @('planId', 'captureTargets') `
    -Adapters @{ 1 = { param($payload) ... } }
```

Collection fields use a dotted path with `[]` to descend into every element of an array, so
a field nested inside a repeated structure is declared once rather than per index.

## Lists and maps are different declarations

A field is declared either as a collection or as a map, never both — registering it as both
is refused, because the two normalizations contradict each other and one would silently win.

The difference is not cosmetic. A declared collection is **repaired**: a scalar, a null, or
an unrolled singleton is rewritten into an array of the right cardinality, because there is
an unambiguous correct answer. A declared map is **only validated**: an array or a scalar
where a map was declared is refused on both write and read, because a map has keys and a
scalar has none, so any repair would fabricate a key the producer never emitted. An empty
map must serialize as `{}`; if it ever reaches JSON as `[]` it can never read back as a
keyed object.

Member access underpins both. `Get-ReviewerStageMember` returns the member itself, not a
container holding it. The obvious implementation — `Write-Output -NoEnumerate $value` — binds
a scalar to its `[PSObject[]]` parameter and hands back a one-element list, which made a
nested object stop answering the has-member test (so a *valid* nested collection path was
rejected as missing) and made a bare scalar look like an object to any shape check. Only a
genuine enumerable needs the no-enumerate guard; a string, a dictionary, and a `PSObject`
already cross the boundary intact.

## Writing

`Write-ReviewerStageArtifact` takes a caller-specified path — never standard output — and:

- normalizes every declared collection field that is *present*, so a scalar or a null is
  written as an array of the right cardinality — a field the producer omitted is rejected,
  not invented (see below);
- serializes with an explicit depth and an explicit compact-or-indented form;
- writes UTF-8 **without** a byte order mark, with `\n` line endings and exactly one
  trailing newline;
- writes to a temporary file in the destination directory and moves it into place, so a
  reader never observes a half-written artifact.

Normalization is deliberate and one-directional: the writer repairs shape, the reader does
not. A stage that produces a scalar where a collection was declared gets a correct file; a
stage that *consumes* one gets an error.

Repair hides the producer defect that made it necessary, so the writer takes
`-StrictShape`. Under that switch the payload is judged *before* normalization and a
collapsed field is reported rather than repaired — for a stage that would rather learn
about its own bug than have it silently corrected. The writer never invents an absent
field: a declared collection that the producer omitted is a rejection at both ends, because
absent and empty are different facts and a consumer under `Set-StrictMode` throws on the
first but not the second.

## Reading

`Read-ReviewerStageArtifact` rejects, rather than repairs:

| Rejected | Because |
|---|---|
| Missing or wrong `kind` | The file is not the contract the caller asked for |
| Missing `contractVersion`, or a version with no registered adapter | The caller cannot know what it is reading |
| A byte order mark | The file was written by a path that does not honour the contract |
| Unknown top-level or payload fields | Silent extension is how contracts drift |
| Missing required payload fields | The producer failed partway and still wrote |
| A declared collection field holding a scalar or null | The exact collapse this contract exists to prevent |
| A declared collection field that is absent, including one nested under `[*]` | Absent is not empty; a strict-mode consumer throws on it |
| Truncated or empty content | A partial write must not read as an empty result |
| Content preceded by non-JSON text | Something wrote to the file that was not the writer |

Collection field paths may end in `[*]`. Such a path is judged from the parent value rather
than from its elements, so a null or zero-element value is still evaluated — otherwise the
two shapes with nothing to iterate would be exactly the two that escaped validation.

Version adapters are explicit functions registered per source version. Reading a v1 file
under a v2 contract runs the v1 adapter and yields a v2 payload; reading a v3 file under a
v2 contract is an error rather than a hopeful best effort. Existing artifacts therefore
keep working only where somebody wrote the adapter that makes them work.

## Inventory

`Get-ReviewerStageArtifactInventory` returns the artifacts under a directory as a
non-enumerated, read-only collection: zero artifacts is an empty collection rather than
`$null`, one artifact is a collection of one rather than a bare item, and the caller cannot
mutate the result in place. This is the shape that escaped as `ESC-0005`.

## Tests

`tools/Test-ReviewerStageContract.ps1` runs 87 checks: round trips at zero, one, and many
elements; singleton and empty serialization; the no-BOM, single-trailing-newline, no-CR
encoding rules; the indented form; every writer rejection; more than twenty reader
rejections; version adapters in both the accepted and the refused direction; write
atomicity; the read-only inventory; member access returning the value itself rather than a
container; and declared maps, including refusal of an array, a scalar, a null, and an absent
map on both write and read.
