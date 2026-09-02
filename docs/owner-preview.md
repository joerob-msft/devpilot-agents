# Owner convention preview

Runs the `bpm-test-ownership@1` convention specialist over ONE pull request and
writes a capability-scoped preview. No generalist, no provider write, no vote.

This layer is a **composition**, not a new platform. Every step is an existing
reviewed tool; `tools/Invoke-OwnerPreviewCycle.ps1` only authors the documents
those tools read and threads the hashes that bind them together.

## The chain

```
live PR ─► tools/New-ShadowCohortEntryEvidence.ps1        (read-only, 0 models, 0 writes)
        ─► corpus + offline seal recipe
        ─► tools/Save-CorpusReplaySeal.ps1                (non-promotable sealed snapshot)
        ─► New-OwnerPreviewLegacyProjection               (the one new seam, see below)
        ─► tools/Invoke-ReviewerRoleInputCapture.ps1      (builds the stimulus, starts no model)
        ─► tools/Convert-ReviewerBlindedBenchmarkPack.ps1 (binds it)
        ─► tools/Invoke-ReviewerBlindedAcquisition.ps1    (the one model start)
        ─► ConventionSpecialist.ps1 v4 parser
        ─► owner-preview-status.json + owner-preview-report.md
```

`src/Agents/reviewer/Start-ReviewerAgent.ps1` is **neither modified nor
dot-sourced**.

## Why there is no generalist

The evidence request carries **no `executionPlan`**. That section is where a
cohort entry declares its slots, and the schema fixes that array at exactly two
— the generalist pair. Without it the builder emits the preparation-only shape
with no slots section at all (`CohortEntryPackage.ps1:1036-1037`).

So the absence is load-bearing, and the test suite asserts it. If an
`executionPlan` ever appears in the authored request, this preview silently
becomes three model runs whose verdict it would then have to discard.

## Why the capability is pinned in configuration

Blinded acquisition takes a **role**, not a pack. `-Role specialist` runs the
convention specialist over whatever packs the configuration routes, so the only
place the scope can be pinned is the configuration. `prepare` refuses a config
that declares anything other than exactly `bpm-test-ownership`.

## The one new seam

`Convert-ReviewerBlindedBenchmarkPack.ps1` consumes a legacy
`blinded-reviewer-adapter-input` projection. Role capture only re-materializes
the projection the materializer needs when it is *handed* one to re-materialize;
without it a capture still publishes, but not in a shape that satisfies the
materializer's legacy binding check (`docs/role-input-capture.md:71-80`), and
adding that flow is explicitly outside the acquisition tool
(`docs/blinded-acquisition.md:190-193`). The only generator in the repository
was the test helper `New-CaptureBundle`
(`tools/Test-ReviewerRoleInputCapture.ps1:506`).

`New-OwnerPreviewLegacyProjection` adds it minimally: one seed sealing exactly
one resource — the manifest of the snapshot this subject was prepared from.

The three `fixtureIndexBinding` hashes are **derived, not invented**. The test
helper fills them with repeated digits because nothing reads them there; a
production artifact carrying three fields that look like evidence and are not
would be worse than carrying none. Each is bound to something real:

| Field | Bound to |
|---|---|
| `fixtureIndexSha256` | the corpus index this subject was sealed from |
| `fixtureRecordHash` | the seal that published it |
| `originalFixtureFileSha256` | the manifest file those bytes actually are |

## `-RuleCommit`

The convention pack pins the ownership rule by **branch**; a rule bundle section
has to name a **commit**. The operator states it. A wrong value is not a silent
hazard: the builder reads the section through the same read-only contract it
reads a changed file through and refuses it when the bytes disagree with the pin.

## Where evidence lives

`-SubjectRoot` is required, must be absolute, and is refused if it sits inside a
git working tree — captured pull request bytes are private evidence and must not
live where a commit could publish them. The corpus sealer refuses a corpus root
inside the toolkit for the same reason. The conventional root is
`%LOCALAPPDATA%\DevPilot\OwnerPreview\<name>`, with `$HOME/.local-state/...` as
the fallback.

```
<SubjectRoot>/
  subjects/<headKey>/   subject.json, entry/, replay/, pack/
  runs/<headKey>/       capture/, materialized/, acquisition/,
                        owner-preview-status.json, owner-preview-report.md
```

## Subject identity

```
subjectKey = sha256( lower("{org}/{project}/{repositoryId}") + "#" + prId )
headKey    = sha256( canonical{ capability, subjectKey, sourceCommit, ruleSections[],
                                replayManifestDigest, model, configSha256, toolkitHead } )
```

A subject key alone answers "which pull request". It is not enough: two runs over
one pull request at different heads, against different rule bytes, or with a
different model are not the same evidence. `run` recomputes the head key from the
package's own contents and refuses a package that disagrees with its recorded
identity.

## Reading the report

The vocabulary is the capability's own
(`tools/testdata/reviewer-owner-convention-corpus.v1.json`):

- `violation` — the rule reached the declaration and it lacks the owner attribute
- `compliant` — the rule reached it and it carries one
- `unknown` — required context could not be established

`checked` is violations plus compliant. **`unknown` is never folded into either.**
"Nobody could tell" and "this one is fine" are the two answers a reader must never
confuse, and a count that added them would make them indistinguishable at exactly
the moment someone decides whether to act.

```
bpm-test-ownership@1 - checked 9 declarations; 9 violations; 0 unknown
```

There is no `passed`, no severity and no vote. A layer that checked one convention
is not in a position to say a pull request is fine. A pass that did not complete
prints no counts sentence at all, because a "checked 0" line beside a failure
reads like a clean result to anyone skimming.

## What cannot write

- The tool declares no write-capable parameter, and
  `Assert-OwnerPreviewNoWriteSurface` checks that against its own parameter block
  on every run — the interesting failure is the future edit that adds one.
- No write switch may reach a child tool
  (`Assert-OwnerPreviewNoWriteArgument`).
- The builder's verbs are reads; it reports `modelStarts = 0` and
  `providerWrites = 0`, and `prepare` refuses anything else.
- Acquisition fails closed unless its sealed telemetry proves zero writes.
- The status schema fixes `providerWriteCount`, `writeToolInvocations` and
  `generalistModelStarts` to `0` by `const`.

## Usage

```powershell
# Read one pull request and seal an immutable subject package. No model.
./tools/Invoke-OwnerPreviewCycle.ps1 -Action prepare `
    -SubjectRoot "$env:LOCALAPPDATA\DevPilot\OwnerPreview\bpm" `
    -Organization <org> -Project <project> `
    -RepositoryId <guid> -RepositoryName <repo> `
    -PullRequestId <id> -TargetRefName refs/heads/<branch> `
    -RuleCommit <40-hex> -ConfigFile <abs> -Model <model> `
    -CaptureMode live -AgencyPath <agency>

# Run the specialist over a prepared subject.
./tools/Invoke-OwnerPreviewCycle.ps1 -Action run `
    -SubjectRoot <abs> -HeadKey <64-hex> -ExpectedReviewerBaseCommit <40-hex>

# Both at once, and then read the report.
./tools/Invoke-OwnerPreviewCycle.ps1 -Action prepare-run ...
./tools/Invoke-OwnerPreviewCycle.ps1 -Action status -SubjectRoot <abs> -HeadKey <64-hex>
```

Each action prints one machine-readable JSON line. Exit codes: `0` completed,
`1` used incorrectly or a step refused, `2` the pass ran but reached no
schema-valid marker.

## Validation

`tools/Test-OwnerPreviewCycle.ps1` (in CI) runs offline with no network, no model
and no provider. It validates the authored documents against the **same published
schema files** the production tools read, pins the subject-identity properties,
and drives the nine-declaration case through the production v4 parser.

Two honest notes:

1. **There is no sealed PR16991680 snapshot in this repository.** The nine-finding
   truth is recorded as corpus *anchors* (`pr16991680-new-test-methods`,
   `origin: live`, `expectedCount: 9`, constructs `dc2`-`dc10`). The test reads
   those anchors out of the corpus rather than copying them, so it cannot drift
   from the truth it claims to reproduce — but it is reproducing a recorded
   verdict set, not replaying sealed provider bytes.
2. **The live `prepare` path is proven structurally, not executed against a live
   host in CI.** `capture.mode` selects `live` or `replay`; the tests exercise the
   wiring and the documents. One optional read-only live preflight can be run by
   an operator outside CI. Zero models and zero writes either way.

A third detail worth knowing: the v4 contract caps explanatory notes at eight, so
nine violations cannot all be annotated. The test asserts the nine verdicts
survive that — a capped note list must never cost a finding.
