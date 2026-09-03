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

The v3 request does bind the specialist and discovery model identities in
`capture.models`. That list is snapshot provenance required by production role
capture, alongside the exact reviewer-script and prompt-file digests; it creates
no slot and grants no launch authority.

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
proves a marker naming another pull request or carrying a nonce this run did not
issue is refused rather than counted, and drives the nine-declaration case
through the production v4 parser.

## Hourly declared queue

`tools/Invoke-OwnerPreviewQueue.ps1` is the Layer 2 Windows Task Scheduler
harness. It does not discover pull requests and does not paginate or reorder
anything: its validated local JSON configuration declares at most ten pull
requests, and each tick considers them in that exact order. A tick processes at
most one unprocessed head by invoking this Layer 1 tool with `-Action
prepare-run`.

Each entry names the live organization, project, repository ID/name, pull
request ID, target ref, reviewer config, authoritative rule commit, model,
reviewer base commit, agency executable, and exactly
`bpm-test-ownership@1`. `sourceHeadMode: fixed` additionally requires the
expected 40-hex source head. `refresh-before-first-run` binds the live head
captured on its first run; it is not a standing "run every new head" discovery
mode. To process a later head, update the declaration.

The queue's `headKey` binds subject and source identity, target identity, exact
rule repository/path/branch/commit/section/hash/length, supported-model
registry, selected model, reviewer config, prompt and reviewer-script hashes,
replay manifest digest, and toolkit head. Its HMAC-authenticated atomic ledger
and immutable per-head journal/index/artifact records live under the required
external state root. A key must exist before any record; missing-key or
key/record mismatch is a refusal. States are `pending` -> `running` ->
`completed|incomplete|blocked`. A dead `running` record becomes
`incomplete/interruptedUnknown` on the next tick and never retries
automatically. The only retry path is:

```powershell
./tools/Invoke-OwnerPreviewQueue.ps1 -Action requeue `
  -ConfigFile C:\stable\owner-queue.json -StateRoot C:\private\owner-state `
  -HeadKey <64-lowercase-hex> -Reason "operator inspected evidence"
```

The requeue reason is appended to the signed audit history. One cycle reserves
at most the production specialist's three starts, allows zero provider writes,
zero write-tool invocations and zero generalist starts, and has a 50-minute wall
limit. Any contrary telemetry blocks the record. The index reports only this
capability: declarations checked, Owner violations, unknown,
`notInReach`/`notRouted`, rule provenance, terminal/schema status, attempts,
starts, latency, and write counts. It has no global pass, approval, verifier,
reconciliation, or vote.

### Scheduler deployment

The scheduler must point at a **stable ordinary checkout** whose `.git` is a
directory and whose named ref resolves to the exact configured toolkit head.
Linked worktrees and paths under `copilot-worktrees` are refused. Consequently,
install from a promoted stable checkout, not from a Copilot session worktree.
The task creates **zero Copilot/app sessions and zero worktrees per tick**; it
starts `pwsh` directly.

```powershell
# Shows the exact principal/action/trigger/settings without registering a task.
./tools/Invoke-OwnerPreviewQueue.ps1 -Action install-dry-run `
  -ConfigFile C:\stable\owner-queue.json -StateRoot C:\private\owner-state

# Idempotent registration under the current interactive user.
./tools/Invoke-OwnerPreviewQueue.ps1 -Action install `
  -ConfigFile C:\stable\owner-queue.json -StateRoot C:\private\owner-state
```

The task is named `DevPilotOwnerPreview-<instanceName>`, uses interactive logon,
limited run level, no stored password or elevation, an hourly trigger,
`IgnoreNew`, and a 55-minute execution limit. `task-status`, `disable`, and
`uninstall` manage only that task. Uninstall preserves the ledger and all
evidence. App Automation is not a scheduler for this layer.

`tools/Test-OwnerPreviewQueue.ps1` drives the queue offline with a fake
prepare-run boundary and the committed result shapes. It registers no task,
contacts no provider, and starts no model.

## What live validation established

The read-only proof used active PR `16705856` at source commit
`80f5ebbd12df72830e0ceee5e9ec84a4c9564946`. `prepare` reported zero model
starts and zero provider writes and published snapshot
`pr16705856-i1-offlinecorpusseal`, manifest digest
`c5f6de464cd5b53a881e829845b877d6dc75477b5aecbdd83d47eada194c5ec9`.
Its classification is `offlineCorpusSeal`, `nonPromotable: true`.

The authoritative EngHub `master` branch resolved to
`8cb115690a241634f89cf937ec12c79746651861`. The provider returned the whole
`AutomatedTests.md` file unchanged into the sealed corpus: 20,261 bytes, SHA-256
`d6698af51dc66142deb5dd8169fd02b4f809f5578f026d8c2911f34ae7eca144`.
The shared extractor separately cut `## Claim ownership`; it remains exactly
569 bytes with SHA-256
`bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f`.

`run` then completed the production capture → preserved-lineage materialization
→ blinded acquisition → V4 parse → status chain using only the committed
`owner-preview-v4-unknown` offline adapter. Role capture recorded zero boundary
hits, model/Agency/provider processes, live reads, writes, leases, plans and
tokens. Acquisition reported zero premium requests and zero provider writes; its
one accounted model attempt was the deterministic offline adapter, not a real
specialist start. The authenticated V4 marker completed with 32 `unknown`
constructs, zero violations, and zero compliant claims.

The proof artifacts live outside the repository under
`C:\Users\daviburg\.copilot\private\owner-preview-live-proof-20260903T052324Z`.
The recorded head key is
`42ca5a9ed65a3989b623f3a78760588c7631d9335d540fd3009bc656eb0079f4`.
