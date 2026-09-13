# Owner parity qualification

`DevPilot.OwnerParity` is the execution and reporting layer above the read-only
Owner observer and the preview-only v2 orchestrator. It runs no provider write,
does not authorize delivery, and requires the v2 state root to be separate from
both v1 and this repository.

The qualification manifest identifies one signed v1 queue record and one v2
replay manifest, normalized observation, or explicit unavailable reason per
cohort entry. Expected fail-closed manifest rejection and absent exact replay
evidence become blocked entry results rather than aborting the cohort. Private
manifests, observations, source bytes, adjudication identities, and detailed
reports stay outside git. Only the fixed-shape sanitized aggregate summary is
suitable for commit. Output parent directories must already exist; device,
UNC, substituted-drive, provider-drive, and reparse-point aliases are rejected.

For a rigorous run, record every critical v1 file in `attestation.critical`
with its repository-root-relative path, exact SHA-256, byte length, and
`critical:<path>` binding. Declare each permitted volatile file separately in
`attestation.volatile` with its initial prefix hash/length, bounded growth, and
`affectsParityInputs: false`. The coordinator rejects unexpected files, copies
the attested bytes to a fresh immutable snapshot under the separate v2 state
root, reads v1 only from that snapshot, and compares the original files again
after qualification.

```powershell
./tools/Invoke-OwnerParityQualification.ps1 `
    -V1StateRoot C:\private\owner-v1 `
    -V2StateRoot C:\private\owner-v2-parity `
    -QualificationManifestPath C:\private\qualification.json `
    -PrivateReportPath C:\private\parity-report.json `
    -SanitizedSummaryPath .\docs\owner-parity-summary.json
```

Every gate is one of `passed`, `failed`, `blocked`, or `notMeasured`. A
synthetic fixture cannot pass finding-retention or false-positive gates.
Unknown or uncovered v1 units are never inferred compliant when v2 lacks a
unit-level outcome. Counts and telemetry use explicit `measured`,
`unavailable`, or `notMeasured` states so a measured zero cannot be confused
with absent evidence.

The eight gates are:

1. 100% retention of adjudicated verified v1 method findings.
2. Zero new comment-eligible false positives against complete truth.
3. Equality for mutually exposed subject/head/target/rule/capability fields
   plus versioned canonical semantic finding keys. Raw path/anchor forms and
   provider dedupe markers remain audit evidence, not equality requirements.
4. No unknown or uncovered v1 unit converted to a known outcome.
5. Zero v2 provider or write-tool activity.
6. Candidate completion and retained-unit rates no lower than v1.
7. Explicit latency, model-start, attempt, and operator-intervention
   accounting, including explicit unknowns.
8. Byte-identical critical v1 inputs plus only explicitly declared,
   prefix-preserving, bounded append-only volatile changes.

Offline deterministic or recorded-byte replay proves only retrospective parity
for the preserved cohort. Prospective real-model parity remains separately
blocked until the model launcher can prove its no-tools and no-provider-write
ceiling without widening permissions.

## Contract-remediated preserved-evidence qualification

The committed [sanitized aggregate](owner-parity-summary.json) covers the same
five preserved cohort entries using a new v2 state root and 3,260 exact
critical references plus one explicitly declared append-only volatile file.
Four candidates now complete with normalized accounting. All 6 verified v1
method findings have canonical structural matches, but deterministic attribute
judgments remain non-semantic evidence.

| Gate | Result | Evidence |
|---|---|---|
| Finding retention | `blocked` | 6 of 6 reproduced, but deterministic oracle output is not semantic evidence |
| Eligible false positives | `blocked` | No entry has qualifying semantic truth, so the aggregate is unavailable rather than a measured zero |
| Binding equivalence | `blocked` | 38 measured canonical comparisons pass; the unavailable fifth entry remains blocked |
| Unknown integrity | `blocked` | 16 unknown, advisory, uncovered, or incomplete outcomes lack candidate proof |
| Write isolation | `blocked` | Four completed replays measured zero provider/tool writes; the unavailable entry remains blocked |
| Completion reliability | `blocked` | Four candidates completed, one remains unavailable, and semantic retention is still unmeasured |
| Latency accounting | `blocked` | 96 explicit measurement states pass; the unavailable entry contributes 12 blocked states |
| Rollback proof | `passed` | 3,260 critical files were byte-identical; the sole declared volatile file preserved its prefix and file identity within bounded growth |

The separate launcher layer now proves a Copilot CLI interface with a literal
empty tool set but fails closed because the supported prompt transport exposes
the bounded stimulus in process arguments. Prospective real-model parity
remains blocked until a supported confidential prompt channel is available.
This evidence does not support cutover or writer compatibility.

These deterministic contracts make the next semantic parity run measurable;
they do not support cutover, deployment changes, or writer compatibility. The
separate no-tools launcher remains unavailable at the confidential prompt
transport gate; a later layer must first resolve that blocker and then run it
against independently adjudicated semantic evidence.
