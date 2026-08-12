# Offline snapshot replay

A reviewer cycle reads a pull request from a repository host. Once that pull
request moves on, the evidence that produced a particular review is gone, and
"we fixed the miss" becomes an assertion nobody can check.

Replay closes that gap. An operator records the reads one cycle made, and a
later build of the agent re-runs the **whole** stack against those exact bytes:
source transport, convention packs, review facts, both generalist passes, the
convention specialist, cross-verification, the delivery gate and every preview.
No repository is contacted.

## What replay is, and what it is not

Replay is **evidence about a recorded pull request state**. It is not a review,
and it is not a reproduction of a live run.

- It is permanently preview-only. Every write switch, every gate switch and
  both promotion paths are refused at startup, the delivery authorization is
  forced to `PreviewOnly` whatever the pass count, and the artifacts it writes
  are sealed under a separate key domain so promotion cannot verify them.
- The model's tool grant is denied. The wrapper's own reads come from the
  snapshot, but a model tool would reach the host through the CLI's
  credentials, not through the replayed session, and the local file tools would
  read the working tree, which is neither the snapshot nor the reviewed commit.
  So in replay the entire code-defined tool ceiling goes on the deny list.
  Each pass keeps its own allow list - substituting one would offer a pass a
  tool its own ceiling withholds - and the deny always wins, so nothing in it
  survives. It is denied rather than emptied because an empty allow list makes
  the launcher omit the tool flags entirely, which restores Copilot CLI's
  default discovery. The model therefore cannot look anything up for itself,
  which makes a replay a **lower bound** on what a live run would find. The
  preview says so in as many words.
- Replay state is separate state. A replay writes under
  `<StateDir>/replay/<snapshotId>/`, so it cannot burn a real pull request's
  attempt budget, supersede its gate decisions, or leave preview artifacts a
  later live run would read back.

## The seam

Almost every repository read in this toolkit goes through `Send-AgentMcpRequest`.
A replay session is served there, which is why the layers above it need no
changes and see no difference: `Invoke-AgentMcpTool` still validates the
envelope, `ConvertFrom-AgentMcpResourceContent` still enforces the exact URI,
the MIME allow-list, canonical base64, the size bound and UTF-8 strictness. A
replayed payload gets exactly the hostile-input treatment a live one gets.

A replay session has no process and no socket. There is no code path from one
to the network:

- only `tools/call` is answered; `initialize` and every notification are refused;
- a tool or action outside the code-defined read ceiling is refused, at load
  time so a snapshot cannot contain one, and again at serve time so no caller
  can ask for one;
- a read the snapshot does not carry throws, naming the exact request. It never
  falls through to a live read.

**"Almost" matters.** The MCP seam is one of two live source transports. The Azure
CLI source fallback (`review.sourceTransport.azureDevOpsCliFallback.enabled`,
see [source-transport.md](source-transport.md)) does not go through
`Send-AgentMcpRequest` at all: it resolves `az` on `PATH`, runs it, and then
calls the REST API directly. Treating the MCP seam as the only egress is exactly
the assumption that once let a configured replay contact the live service, so
schema-v2 replay bypasses both live transports:

- live capture writes one canonical source-transport artifact containing its
  exact iteration/common/source/target/change-set binding, transport mode,
  report, coverage record, gate and rendered sealed block;
- the snapshot manifest hashes that artifact and includes its descriptor in the
  manifest digest;
- replay validates the binding, policy hash, canonical JSON, artifact digest,
  reconstructed coverage record and gate, and exact rerendered source block
  before returning it. This return occurs before capability probing, MCP source
  reads or the Azure CLI branch;
- `New-ReviewerSourceAzCliInvoker` refuses outright, whichever call site got
  there — it checks `DEVPILOT_REVIEWER_REPLAY_ACTIVE` in the environment as well
  as script scope, so the refusal survives being loaded into a module, a thread
  job or a child process, where a script-scope flag would be invisible.

`DEVPILOT_REVIEWER_REPLAY_ACTIVE` is set by the reviewer, for the reviewer. Any
non-empty value means replay, including `0` and `false`, because a safety guard
is the wrong place to parse intent; assigning `""` deletes the variable in
PowerShell, so removal is the only way to express "off". The reviewer clears it
at startup before anything can read it and sets it only on the replay path, so a
leftover from an earlier replay in the same shell cannot silently disable the
live fallback in a later live run — and if one is somehow present anyway, the
refusal says the variable is stale rather than claiming a replay is happening.

Every schema-v2 replay artifact records the captured live mode:
`mcpFlat`, `azureDevOpsCliFallback`, or `legacyMcp`. Schema-v1 snapshots remain
loadable for compatibility and disclose `snapshotLegacy`; they do not claim
live/replay source-coverage parity.

## The snapshot

A snapshot is a directory named as a single child of an explicit replay root:

```
<replay root>/
  <snapshot name>/
    manifest.json
    source-transport.json
    payloads/...
```

`manifest.json` is strict: exact keys, exact types, code-defined caps (4096
resources, 24 MB per payload, 64 MB in total). It records

- `binding` - organization, project, repository id, pull request id, source and
  target commit, and the change-set hash;
- `bindings` - the config, script and prompt hashes and the model list the
  capture ran under;
- `resources[]` - for each recorded read, the tool, the exact arguments, the
  SHA-256 of the canonical `{name, arguments}` that is its lookup key, and the
  payload file with its own hash and byte length;
- `sourceTransport` (schema v2) - the recorded live mode and the canonical
  source-transport artifact's relative path, SHA-256 and byte length;
- `manifestDigest` - a canonical digest over everything above.

Every payload is the exact JSON-RPC response line the read returned.

### What the digest does and does not prove

`manifestDigest` is unkeyed. It proves the manifest still describes its own
payloads - it catches corruption, a partial edit, and a recorder that disagrees
with this reader. It does **not** prove the snapshot was not edited, because
anyone who edits one can recompute it.

Binding a run to a snapshot an operator actually vouched for is the job of
`-ReplayManifestDigest`, which the reviewer requires. Print it once when the
snapshot is made, keep it where the snapshot is not, and pass it on every run.

### Snapshot input is treated as hostile

- The snapshot name must be a single path-free name; `..`, separators, drive
  letters and alternate data streams are refused.
- Every payload path must be a plain relative path, and its resolved location
  must still be strictly inside the snapshot after the filesystem has applied
  its own casing and short-name normalization.
- Any component that is a reparse point - a symlink or a junction - is refused.
  Hard links are deliberately not chased: a hard link can only ever supply the
  exact bytes the manifest already pins by SHA-256.
- Payloads are read and hashed once at load and held in memory, so nothing on
  disk can change under a run, and re-hashed at every serve.
- Duplicate lookup keys are refused: a snapshot must answer each request one way.

### Determinism

Lookup keys and the manifest digest are computed from an ordinally-sorted
canonical JSON with explicit string escaping. Culture-sensitive ordering would
make a snapshot captured on one host fail to load on another; delegating
escaping to the host serializer would make the digest a function of the
PowerShell build. Non-integral numbers and date values are refused rather than
rendered ambiguously - PowerShell's JSON reader turns extended-format ISO-8601
strings into `DateTime`, which is why `capturedUtc` uses the basic
`yyyyMMddTHHmmssZ` form that stays a string on both sides.

A replay preview prints two digests:

- **replay input digest** - over what the wrapper computed from the snapshot
  alone (the source-coverage record and the tool grant). Two replays of one
  snapshot **must** produce the same value; a difference is a determinism defect
  in this toolkit.
- **replay outcome digest** - over the wrapper's normalized decisions: the
  sorted anchors and severities of the candidates it would post, the counts and
  the recommended vote. Comment prose is excluded, so two models that say the
  same thing differently agree. The set of anchors is still downstream of a live
  model, so a difference here is a real semantic difference and is reported as
  one rather than smoothed over.

## Making a snapshot

Capture and sealing are separate on purpose. Capture is host-specific and
credentialed; sealing is pure, so it can be tested, reviewed and run anywhere.

`tools/Save-AgentReplaySnapshot.ps1` does the sealing. It takes payload files an
operator has already captured plus a recipe naming the tool and arguments each
one answers. For exact source replay, live capture also uses
`-CaptureSourceTransportArtifactPath` and the sealer receives that file through
`-SourceTransportArtifactFile`, together with independently supplied
`-IterationId` and `-CommonCommit`. The sealer requires those values to match
the artifact before it writes the schema-v2 manifest:

Use `-CaptureSourceTransportOnly` with the capture path when the evidence must
be sealed before any model sees it. The wrapper then requires the source gate
to pass for the explicitly named `-PullRequestId`, writes the artifact, and
stops before authoritative-source reads or model launches. This mode also
requires `-Once`.

```json
[
  {
    "tool": "repo_pull_request",
    "arguments": { "action": "get", "project": "P", "repositoryId": "...", "pullRequestId": 1 },
    "payloadFile": "payloads/pr-get.json"
  }
]
```

It refuses to seal a recorded write, computes every hash and the manifest
digest, and then loads what it just wrote to prove the result is a snapshot this
build accepts.

`src/Agents/reviewer/testdata/replay-v1/synthetic-pr` is a committed synthetic
snapshot - invented organization, invented repository, a synthetic GUID and two
made-up files - that exercises the mode end to end without any real repository
content. `tools/Test-ReplaySnapshot.ps1` drives it.

## Sealing offline from a captured corpus

Sometimes the capture already happened and what survives is not payload files
laid out for the sealer but a research **corpus**: a directory of captured bytes
plus a `corpus-index.json` binding every one of them to a path, a SHA-256 and a
byte length. `tools/Save-CorpusReplaySeal.ps1` turns that into a schema-v2
snapshot without contacting anything.

```pwsh
./tools/Save-CorpusReplaySeal.ps1 `
    -CorpusRoot <corpus> -CorpusIndexSha256 <64 hex> `
    -Recipe <private recipe>.json -ReplayRoot <private replay root>
```

It has no live seam and no fallback: no MCP session, no repository host, no `az`,
no child process, no network. The only bytes it can read are the ones the index
names plus, when the recipe asks for it, one hash-pinned versioned policy file
(see below). The only way it can fail to find something is by refusing.
`-CorpusIndexSha256` is mandatory, because an index that is merely
self-consistent proves nothing - whoever edited it could recompute whatever it
contains. The tool also refuses a corpus or an output root inside this
repository, since a seal is private evidence about a real pull request and is
never committed. Containment is checked against *real* paths: every component of
an operator-supplied corpus root or replay root is walked, and a reparse point
anywhere along either one is refused rather than followed, because a junction is
otherwise a one-line way to make "outside the repository" resolve back inside it.

That guard lives in `Save-ReviewerCorpusSeal` itself, not only in the CLI, so a
caller reaching the library directly gets the same protection - and it runs
twice, once before staging and once immediately before publication, refusing if
the root moved in between. PowerShell cannot hold a directory handle across a
rename, so the window cannot be closed entirely; two checks and a root-identity
comparison are the strongest defence available here, and the alternative of
checking once was strictly worse.

### The recipe states everything twice

`src/Agents/reviewer/schemas/reviewer.offline-corpus-seal-recipe.v1.json`
describes the private recipe. It is deliberately redundant with the corpus: it
must independently bind the organization, project, repository, pull request and
iteration; the source, common and target commits; the authoritative change-set
digest *and* its exact path order; every changed file's right-hand payload, hash,
length and spans; the siblings, rules, threads and facts the prompts consume; the
policy, config, script, schema and prompt hashes; the source transport's mode,
coverage record, gate and rendered block; the capture provenance and
status-at-capture; and its own non-promotability.

Redundancy is the point. Anywhere the recipe and the corpus disagree, one of them
is wrong and neither is authoritative enough to overrule the other, so the seal
refuses instead of adopting whatever the corpus happens to say. The refusals are
specific: a tampered or missing payload, a wrong index digest, a stale commit or
iteration, another pull request's identity substituted in, an aliased path
(`..`, a backslash, a doubled slash, a drive letter, a case-fold twin), an extra
payload the index never listed, two resources answering one request, a declared
hash or length the corpus does not have, or a source census that leaves an
authoritative changed path neither delivered nor explicitly accounted for as
having no right-hand content.

Completeness is measured against the **change set**, not against the recipe. The
authoritative changed paths and their change kinds are derived from the captured
change metadata, and a path there that does not survive normalization is a
refusal rather than something to filter away quietly - a recipe cannot shrink the
denominator by declaring fewer files or by naming a path the change set spells
differently. Every authoritative path is passed through the transport report, so
its coverage fraction is the real one. A path may be declared as carrying no
right-hand content only when its authoritative change kind proves it (a deletion
or an otherwise source-free change); anything else must arrive with sealed bytes.
Declared change kinds are compared to the authoritative ones in both directions.

Identity is bound in three independent parts, not one. The corpus index names the
repository it was captured from as `organization/project/repositoryName`, and the
recipe must agree with all three; the repository GUID is bound separately, from
the captured identity payload. A recipe that binds only the GUID could present
one repository's evidence under another organization and project, so binding it
alone is not accepted. The captured identity must also carry the pull request,
iteration, source, common and target commits, status, draft flag and repository
id, and the **end-of-capture** identity - the only evidence that the pull request
did not move *while* it was being read - is checked against every one of those it
carries (accepting `lastMergeSourceCommit`/`lastMergeTargetCommit` as the names
some captures use). An end identity that declares `matchesInitialCapture: false`,
or that carries nothing checkable at all, is refused.

Sealed right-hand bytes are bound to a **recorded read** of that exact path. A
resource that names this repository and the source commit is held to the whole
contract rather than the part of it that happened to be present: `action` must be
`get_content`, `versionType` must be `Commit`, `project` must be the bound
project, `organization` must match when the recorded tool carries it, and `path`
must be the canonical repository path *itself*. Aliases are refused, not
normalized, so `//src/a.cs`, `/src/./a.cs` and `\src\a.cs` do not bind to
`/src/a.cs`. Two recorded source reads of one path are refused as well.

Nothing is written into the published location until every check has passed. The
seal is built into a staging replay root beside the target, loaded back through
the production loader from staging, and only then moved into place; an existing
snapshot being replaced with `-Force` is set aside first and restored if any step
fails. Output paths are prevalidated as a set before any of them is created, so
an artifact file cannot collide with the manifest, the sidecar, a payload, or an
ancestor directory of one. A refusal is always a refusal to create rather than a
half-written snapshot.

The replay root is validated **in the library**, not only in the CLI, because a
safety property one entry point enforces is a property the other entry point does
not have. A root that is a reparse point, that resolves somewhere other than
where it is named, or that lies lexically or really inside the toolkit working
tree is refused outright. PowerShell cannot hold a directory handle across a
rename, so the defence is to check at every moment that matters rather than once:
the root, the staging root, every payload parent, the artifact parent, the
sidecar and manifest parents, and the publication source and target are each
re-checked for reparse points and boundary containment immediately before they
are written through or moved. Cleanup - the one path that runs even when
everything else failed - never recurses through a reparse point; a link is
unlinked and only real directories are descended into.

### Source transport, offline

The sealed source-transport artifact is either **adopted** from one the capture
recorded - held to exactly the standard `Import-ReviewerSourceTransportReplayArtifact`
applies, which re-derives the coverage record, gate and block from the report and
refuses any divergence - or **derived** from the corpus by running the reviewer's
own report, gate and block renderer over the captured right-hand bytes with a
reader that can only return indexed corpus payloads.

Derivation is not invention, but it is not capture either. The block nonce is
declared in the recipe rather than generated, because a seal must be reproducible
byte for byte; it is a boundary marker, not a secret, and the live path still
generates a fresh one per run.

The policy the report derives under has exactly two admissible origins, and the
recipe must name exactly one of them:

- `corpusPath` - the policy the capture itself recorded, as an indexed corpus
  payload. Preferred, because then the seal is a function of indexed bytes alone.
- `toolkitPath` - a versioned policy file in the toolkit, for the ordinary case
  of a capture that recorded no policy document. It is not a live seam: no MCP
  session, repository host, `az` invocation or child process is involved, just a
  hash-pinned read of a file already under version control. It is nonetheless
  fenced hard, because a mutable file is the weakest input a seal has. The path
  must lie under `src/Agents/reviewer/source/`, must resolve to a real path still
  inside that tree with a reparse point anywhere along it refused, and the recipe
  must pin both its SHA-256 and its byte length - which are verified against the
  bytes actually read and against `hashes.policySha256`. Any divergence refuses
  the seal.

Which route was taken is recorded, not inferred: the classification sidecar
carries `sourceTransport.policyProvenance` of `corpus` or `toolkitSealTime` and
the reference it resolved. `toolkitSealTime` says exactly what it means - this
byte-for-byte reproducibility holds against *that* policy revision, and a reader
who wants to know which one can compare `policySha256`.

### Right-hand content and spans are derived, not declared

Two independent bindings decide what a sealed file shows and where it points, and
neither of them trusts the recipe.

The **bytes**: for every sealed path there must be exactly one recorded read in
the recipe's own resource list whose arguments name this repository, this path
and the bound source commit - and that read's corpus payload must be byte
identical to the sealed right-hand payload. A recipe cannot present one file's
content under another file's name, or last week's content under this iteration's
commit, because the correspondence is recomputed from the read arguments rather
than taken from a declaration. Two reads of the same path at the source commit
are refused: a snapshot must answer that read one way.

The **spans**: `changeSet.spanEvidence` names an indexed hunk census, and the
right-hand span of a hunk is exactly `(newStart, newCount)`. A hunk with
`newCount = 0` removed lines and contributes no span, which is how a pure
deletion legitimately ends up with none. The recipe restates its spans and they
are compared index by index against the derived ones; any divergence refuses.
Evidence describing a path the change set does not carry is refused, as is a
content-bearing path the evidence describes no hunks for - so a span census from
one pull request cannot be spliced onto another's file list, and a recipe cannot
widen or shift a span to pull unchanged code into the reviewer's window.

### What a seal is not

Every seal is permanently non-promotable, and the loader is what enforces it. The
manifest of a schema-v2 seal carries a `classification` block naming the seal
kind, `nonPromotable: true`, and the sidecar's path and SHA-256; the manifest
digest covers that block, so the classification cannot be edited away, and the
sidecar cannot be deleted or altered without failing the load outright. The
binding runs manifest -> sidecar only, since a sidecar that also pinned the
manifest digest would be a hash cycle nobody could compute. A classification may
only ever *withdraw* promotability: `nonPromotable: false` is refused, so the
block is not a channel for granting anything. `New-AgentReplaySnapshot` returns
the classification, and `Assert-AgentReplaySnapshotPromotable` is the one gate
every promotable flow calls - it throws rather than returning a boolean, because
a caller that has to remember to check an answer is a caller that can forget to.
Schema-v1 snapshots are unaffected; a v1 manifest carrying a classification is
refused, an unclassified snapshot classifies as `standard` and stays promotable,
and an absent block contributes nothing to the digest, so existing digests do not
move.

The snapshot id must also contain `offlinecorpusseal`, because the name is the
one label that travels with the snapshot everywhere it is copied, quoted or
logged, and `tools/Save-AgentReplaySnapshot.ps1` refuses both that name and any
directory whose manifest is already classified. Alongside the manifest the tool
writes `offline-corpus-seal.json`, recording `sealKind: offlineCorpusSeal`,
`nonPromotable: true`, a null promotion key domain, `liveSeamCount: 0`,
`liveHostContacted: false`, the corpus binding, the capture provenance, the full
source census, the transport digests and gate, and the evidence actually cited.

It also records `livePostReadRaceCheck: "notPerformed"`, and the tool refuses a
recipe that claims anything else. A seal built from a corpus performed no live
read, so it cannot have re-checked the pull request after one; recording a race
check would be the artifact asserting a guarantee it never obtained. Practically:
a corpus seal is evidence about how the reviewer behaves on captured material. It
can never be the basis for publishing to a live pull request.

`tools/Test-CorpusReplaySeal.ps1` builds a synthetic corpus in a sandbox and
proves both halves - that two seals of one recipe are byte-identical and replay
through the production loader unchanged, and that every rejection class above
fails closed.

## Running a replay

An offline qualification running from an app-created worktree should preflight
the reviewer build with `tools/Assert-ReviewerQualificationPreflight.ps1`.
`OfflineReplay` requires a clean worktree, exact expected `HEAD`, and the
required accepted full ref (for example, `refs/heads/reviewer-layer`) resolving
to that same commit. It deliberately does not require the generated local
branch name to equal the accepted ref and may run from detached `HEAD` when all
other identity checks pass. `LiveDeployment` additionally requires an attached
`HEAD` on the configured branch. Git stderr is retained only for sanitized
failure diagnostics and is never interpreted as identity or dirty-status data.

```pwsh
./src/Agents/reviewer/Start-ReviewerAgent.ps1 `
    -ConfigFile <config> -OperatorAlias <alias> -Once `
    -PullRequestId <the pull request the snapshot was captured for> `
    -Model claude-opus-5 -SecondPassModel gpt-5.6-sol `
    -ReplayRoot <replay root> -ReplaySnapshotName <snapshot> `
    -ReplayManifestDigest <digest>
```

All three replay parameters are required together. `-PullRequestId` is required
and must match the snapshot's binding: the recorded pull-request list is a
moment in that repository's history, and letting it drive candidate selection
would quietly make the run about a different pull request than the operator
pinned. The snapshot's organization, project and repository must match the
running configuration, or the run refuses rather than producing a
self-consistent artifact stamped with the wrong identity.

Long-running qualification slots must be launched through an attached sync/async
shell whose completion notification is owned by the active session, or through an
explicit scheduled/manual wake-up. A detached child process does not wake the
session when it exits and must never be treated as an automatic resume mechanism.
Status checks do not restart, resume, or replace an immutable attempted slot.

`-DryRun` cannot be combined with replay: the self-checks run against their own
fixtures and never open a session.

A snapshot captured under a different config, script or prompt build still
loads, with a warning - a transport change since capture can ask for reads the
snapshot does not carry, and that fails closed with the exact request named.

## One run is not a result

A replay is deterministic in its inputs and not in its model. The same snapshot,
replayed twice, can produce two different readings of the same rule - different
wording always, and sometimes a different verdict. Either run, read on its own,
looks exactly like a result.

So a single replay artifact says so about itself. It carries a residual risk
naming the run as unreconciled, the preview says the same in its header, and the
sealed manifest sets `replay.reconciled = false` with `runsReconciled = 1`.
Nothing about that is advisory: a consumer that wants a stable status has to go
and get one.

`tools/Compare-ReviewerReplayRuns.ps1` is how. Give it the sealed specialist
artifacts from two or more runs of the same snapshot:

```pwsh
./tools/Compare-ReviewerReplayRuns.ps1 `
    -ArtifactPath run1.json, run2.json `
    -KeyPath <state>/artifact-signing.key `
    -OutputDirectory <out> -FailOnDisagreement
```

It refuses to compare runs that are not repetitions of one question. The binding
- pull request, source commit, config, script, specialist library, prompt, both
plans, model, and the enumerated construct table - must be identical, or the
runs are about different code. The replay nonces must all be *different*, or the
"two runs" are one run submitted twice, which is how a single favourable
observation would otherwise launder itself into a stable result.

The semantic form is reconciliation artifact version 2; version 1 remains a
separate legacy schema and is never interpreted as carrying semantic identity.
Then version 2 collapses runs:

- A rule every run read the same way keeps that reading, along with the anchors
  they agreed on.
- A rule the runs read differently becomes `unknown`, and both readings are
  printed. Agreeing on the word while naming different anchors counts as
  disagreement - `violation at mi14` and `violation at mi15` are two findings
  wearing one status.
- A rule some run never accounted for at all is `unknown`.
- Candidate agreement uses `reviewer.semantic-candidate` version 2, not comment
  text. Its sealed canonical payload binds the authoritative rule id and digest,
  normalized file path, anchor kind/line and exact construct spans, issue and
  impact class, severity, confidence, sibling status, deterministic fact and
  violation sets, and structured remediation action/scope/targets/follow-up
  requirement. Candidate/model ids and free-form prose are excluded.
- When those semantics agree, the result is
  `semanticAgreementTextWithheld`: it is one stable evaluation finding, but its
  `comment` is empty and no model wording is selected. Every raw presentation
  variant, including its confidence and sibling status, remains in deterministic nonce/digest order under
  `presentationVariants` until an independently verified renderer can produce
  canonical text.
- A different rule digest, construct/span, issue or impact class, severity,
  confidence, sibling status,
  deterministic evidence/violation set, or remediation identity is a different
  candidate and remains withheld. Missing fields, incompatible semantic schema
  versions, contradictory follow-up fields, unknown remediation targets, and
  malformed identities are withheld rather than inferred.
- Anything else is withheld with the runs that disagreed named.

There is no majority vote and no tie-break. Two runs out of three is not a
result. The reconciliation never picks the interesting reading, the common one,
or the first one - disagreement resolves to `unknown` and stays visible.
Semantic agreement does not add delivery authority: the reconciliation remains
non-promotable, replay-only evaluation output, and canonical presentation text
is deliberately absent.

The reconciliation is sealed under the same derived replay key as the runs that
fed it, so it verifies only there and never against the promotion path. A
live-run artifact cannot be fed to it at all: live artifacts are sealed under
the raw key, and the reconciler reads only the replay domain.
The tool takes the sealed artifact and the signing key from each run. Repeats
belong in separate state directories - that is what keeps them independent -
and each of those mints its own key, so pass one `-KeyPath` per run in the same
order, or a single one if the runs shared a state directory.

Runs are lined up by `ruleRef` rather than by rule id, because one source can
legitimately be transported under two refs and keying on the id would turn that
into a phantom duplicate. The ref is a position in the request list, which is
safe here precisely because the binding already pins the config and both plans -
and the rule id and hash are compared per row anyway, so a run whose `rs2` is
about a different rule than the other's `rs2` disagrees rather than being
quietly lined up.
### Declaring the run set before you look

An operator who picks which runs to compare after seeing their results has not
reconciled anything; they have chosen an answer. So the set is declared and
sealed first:

```pwsh
./tools/Compare-ReviewerReplayRuns.ps1 -DeclareRunSet `
    -SnapshotName pr12345 -SnapshotManifestDigest <digest> `
    -PlannedRunCount 4 -Purpose "calibration at head abc1234" `
    -KeyPath <state>/artifact-signing.key -OutputDirectory <out>
```

Then run the replays, and reconcile against the declaration:

```pwsh
./tools/Compare-ReviewerReplayRuns.ps1 `
    -ArtifactPath run1.json, run2.json, run3.json, run4.json `
    -KeyPath k1, k2, k3, k4 `
    -RunSetPath <out>/runset-<id>.json -RunSetKeyPath <out>/artifact-signing.key `
    -OutputDirectory <out> -FailOnDisagreement
```

The comparison refuses an artifact that replayed a different snapshot, and
refuses a set that is short or topped up. The declaration is sealed before any
run exists, so it normally has its own key; pass `-RunSetKeyPath` unless it
shares a state directory with the first run.

**Do not edit the reviewer while a qualification set is in flight.** The
binding covers the script and the specialist library, so a run that finishes
after an edit binds differently and the set is spoiled - which the tool will
tell you, having refused to reconcile it.