# Stage file contract

Coordinator stages hand work to child processes and read the result back. When that result
arrives on standard output, or without a declared version, or with a depth the host chose,
the boundary is where shape is lost: a one-element array reads back as a scalar, an empty
collection reads back as null, and a diagnostic line printed by a well-meaning helper reads
back as part of the contract.

`src/Agents/reviewer/StageContract.ps1` makes that boundary explicit and fails closed.

> **Adoption status: none.** No production stage calls `Write-ReviewerStageArtifact` or
> `Read-ReviewerStageArtifact` yet. This layer ships the contract, its schema, and its
> enforcement tests so that the stages can be migrated onto it one at a time; until a stage
> is migrated, nothing it writes is covered by anything described below. Migrating the
> stages changes live coordinator behaviour and is deliberately out of scope for a
> prerequisite change that runs no models.

## The envelope

Every stage artifact is a JSON object with a fixed shape, validated against
[`reviewer.stage-envelope.v1.json`](../src/Agents/reviewer/schemas/reviewer.stage-envelope.v1.json):

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
Register-ReviewerStageContract -Kind 'reviewer.specialist.plan' -Version 2 `
    -CollectionFields @('captureTargets', 'evidenceFactIds', 'notes[].tags') `
    -RequiredFields @('planId', 'captureTargets') `
    -Adapters @{ 1 = { param($payload) ... } }
```

Collection fields use a dotted path with `[]` to descend into every element of an array, so
a field nested inside a repeated structure is declared once rather than per index.

## Writing

`Write-ReviewerStageArtifact` takes a caller-specified path — never standard output — and:

- normalizes every declared collection field, so a scalar, a null, or a missing field is
  written as an array of the right cardinality;
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

`tools/Test-ReviewerStageContract.ps1` runs 62 checks: round trips at zero, one, and many
elements; singleton and empty serialization; the no-BOM, single-trailing-newline, no-CR
encoding rules; the indented form; every writer rejection; more than twenty reader
rejections; version adapters in both the accepted and the refused direction; write
atomicity; and the read-only inventory.
