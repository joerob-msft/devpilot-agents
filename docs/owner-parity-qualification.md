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

For a rigorous run, record `expectedV1Snapshot` in the private manifest before
deriving any replay candidates. The coordinator compares that snapshot with
both its immediate pre-run snapshot and its post-run snapshot, so activity
between evidence capture and execution cannot be hidden by a narrow snapshot
window.

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
unit-level outcome. Missing latency, model-start, attempt, or intervention data
must remain the literal value `unknown`.

The eight gates are:

1. 100% retention of adjudicated verified v1 method findings.
2. Zero new comment-eligible false positives against complete truth.
3. Exact equality for mutually exposed subject, head, target, rule,
   capability, and finding-anchor bindings.
4. No unknown or uncovered v1 unit converted to a known outcome.
5. Zero v2 provider or write-tool activity.
6. Candidate completion and retained-unit rates no lower than v1.
7. Explicit latency, model-start, attempt, and operator-intervention
   accounting, including explicit unknowns.
8. Identical v1 file count, byte count, newest timestamp, and content root
   before and after qualification.

Offline deterministic or recorded-byte replay proves only retrospective parity
for the preserved cohort. Prospective real-model parity remains separately
blocked until the model launcher can prove its no-tools and no-provider-write
ceiling without widening permissions.

## First preserved-evidence qualification

The committed [sanitized aggregate](owner-parity-summary.json) covers five
preserved cohort entries. Two method-bearing entries completed through the v2
parser and offline replay path and reproduced all 6 verified v1 method
findings, with no observed adjudicated eligible false positives. Because the
judgments came from a deterministic attribute oracle rather than preserved
model output, those observations are structural evidence and do not pass the
semantic retention or false-positive gates. The remaining entries expose the
limits rather than converting them into successes:

| Gate | Result | Evidence |
|---|---|---|
| Finding retention | `blocked` | 6 of 6 reproduced, but deterministic oracle output is not semantic evidence |
| Eligible false positives | `blocked` | 0 observed; deterministic provenance and three unavailable entries prevent qualification |
| Binding equivalence | `failed` | Four exact path/anchor representation mismatches and five dedupe-accounting mismatches |
| Unknown integrity | `blocked` | 16 unknown, advisory, uncovered, or incomplete outcomes lack candidate proof |
| Write isolation | `blocked` | Completed replays recorded zero writes; three unavailable results lack normalized write accounting |
| Completion reliability | `blocked` | Two candidates completed, one did not, and two outcomes remain unknown; the unknown outcomes could still close the completion-rate gap, while semantic retention remains unmeasured |
| Latency accounting | `blocked` | Completed replays are accounted; unavailable results have no normalized candidate accounting |
| Rollback proof | `failed` | v1 changed after the original snapshot, and `runner\scheduled.log` also changed during the final coordinator run |

Prospective real-model parity is also `blocked`. This evidence does not support
cutover or writer compatibility.

The smallest safe next layer is a contract-only follow-up that canonicalizes
v1/v2 path representation before comparison, makes zero-unit and advisory-only
v2 runs emit valid normalized observations, and permits exact local source bytes
to be referenced without relaxing the manifest secret scanner. A separate
no-tools real-model launcher is still required for prospective semantic parity.
