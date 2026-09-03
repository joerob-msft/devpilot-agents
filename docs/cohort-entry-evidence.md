# Typed cohort-entry evidence

`tools/New-ShadowCohortEntryEvidence.ps1` builds **one immutable, sealed cohort-entry
evidence package** from **one versioned operator request**, using only the already-reviewed
read-only capture surfaces, and publishes a typed package that
`tools/ShadowRunCoordinator` and the cohort manifest accept **without translation**.

> **It launches no model, it writes nothing to a provider, and it makes no reviewer
> judgement.** There is no expected-findings field, no oracle, no severity and no verdict
> anywhere in its request schema or its output. `tools/Test-ShadowCohortEntryEvidence.ps1`
> fails the build if that stops being true — it scans the schema for an oracle-shaped
> property name and refuses one.

## What it is for

A Gate5 operator assembling a cohort entry by hand has to get a long list of exact things
right at once: which alias a field goes by on which tool, whether a repository identity is
the raw Azure DevOps shape or the reduced one, whether a change set arrived as an array or
collapsed to a single object, whether a file was read at the source commit or the common
commit, whether a rule section still matches its pin, whether the target ref in the config
is the same target ref the pull request has now, and whether the census is in the ordinal
order the coordinator digests. Every one of those has been an incident. Each incident was
fixed once, in the place it happened, and then re-made the next time somebody assembled an
entry by hand.

This builder assembles the entry **once**, mechanically, against the wrapper contract, and
then refuses — with an exact code — anything that does not match. What an operator supplies
is a request. What they get back is a sealed directory or a catalogued refusal.

## The operator request

`src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v1.json` through
`reviewer.cohort-entry-evidence-request.v3.json`, with the matching `schemaVersion`
and `kind: reviewer-cohort-entry-evidence-request`. Strict throughout —
`additionalProperties: false` on every object, so a misspelled field is a refusal rather
than a silently ignored intention.

| Section | What it fixes |
| --- | --- |
| `correlationId` | One id carried into the coordinator request, the audit and every child log. |
| `toolkit` | Repository root, the exact head commit, and the ref that head must be on. |
| `subject` | Organization, project, repository **id** and **name**, pull request id, and the target ref the entry is claimed against. |
| `reviewer` | Config path, repository path, operator alias, PowerShell path, child timeout, planned run count, run-set key. |
| `ruleBundle` | Where the pinned rules come from, the declaration digest, and each section's source binding, path, commit, heading and digest. |
| `capture` | `replay` or `live`, the replay root, snapshot name and manifest digest, the agency path, and the request timeout. |
| `coverage` | Maximum changed files, file bytes, sibling files and threads, and the minimum changed-path coverage percent. |
| `output` | Where the package is published, its entry id, its cohort ordinal, and the seal key. |

Both `subject.repositoryId` and `subject.repositoryName` are required, because the wrapper
contract uses **both** and does not use them interchangeably — see the alias table below.

### v2: the optional execution plan

`reviewer.cohort-entry-evidence-request.v2.json`, `schemaVersion: 2`, is v1 plus **one**
optional section, `executionPlan`. Nothing else moved. A v1 request stays loadable and
still produces the byte-identical no-slot output it always did; a v2 request that omits
`executionPlan` behaves exactly like a v1 request. Declaring `executionPlan` at
`schemaVersion: 1` is a refusal (`CE700`), so the version and the capability cannot drift
apart.

Without a plan the builder emits a coordinator request with no `slots` section: the entry
is *prepared*, and a slot declaration is somebody else's later edit. With a plan the
builder emits the **complete** request — `slots`, `reconciliation` and `delivery` — during
creation, before the request digest is taken. That is the whole point of the section. The
digest covers the entire file, so there is no "after the hash" for a third slot, a write
authorization or a redirected output directory to appear in; the tests demonstrate this by
appending a slot to the published request and showing the digest no longer matches.

| `executionPlan` field | What it fixes |
| --- | --- |
| `shadowSlotsEnabled` | Must be `true`. A plan that declares slots and disables them is a contradiction, not a configuration. |
| `slots` | Exactly two, named `slot1` then `slot2` **by position**, sharing one reviewer script path and digest, with distinct state directories and terminal artifacts. |
| `models` | The generalist pair, the convention specialist and the convention verifier, each restated and each checked. |
| `supervision` | Per-call, slot, activity and grace timeouts. Per-call may not outlive the slot supervising it (`CE710`). |
| `reconciliation` | Enabled, with a required run count that equals the declared slot count. |
| `delivery` | `PreviewOnly`, comments/votes/gates all `false`, `providerWriteBudget` exactly `0` — every one of them a schema `const`. |

### v3: explicit rule source and section

`reviewer.cohort-entry-evidence-request.v3.json`, `schemaVersion: 3`, keeps the
v2 execution-plan shape and makes rule sources explicit. Every v3 section
must name `organization`, `project`, the rule repository GUID, and the exact ATX
heading whose digest and byte length are pinned. Organization and project must
match the subject; the repository may differ.

The provider still returns and the corpus still seals the whole file, byte for
byte. The pin is checked separately against the shared
`Get-ReviewerMarkdownSection` cut. Missing or repeated headings and digest or
length drift refuse as `CE310`. v1/v2 keep their historical subject-repository,
whole-file behavior and do not accept the new fields.

An optional `capture.models` array binds supported model identities into the
sealed replay snapshot for later role-input capture. It is provenance only:
without `executionPlan` the entry still emits no slots, consumes no launch
authorization, and derives a zero model-start bound.

**The launch authorization is derived, never supplied.** A request may not name
`launchAuthorizationTokenPath` anywhere — not on a slot, not on the reconciliation, not on
the delivery. Doing so refuses under **`CE716`**. The builder derives the one path a
published authorization can occupy:

```
<output.root>.preparation/qualification/runset/launch-authorization.token
```

which is exactly where `Invoke-ReviewerReplayQualification.ps1 -Mode Declare` mints and
publishes it, read-only, inside its publish transaction. That path is known from the output
root the request already declares, so it is stamped into the plan *before* the coordinator
request is hashed; nothing is rewritten afterwards.

This closes a real defect. Previously the operator supplied that path and nothing compared
it to the run set the entry's own preparation would publish. An entry could seal, pass
`Assert-ReviewerCohortEntrySealable`, pass a cohort walk and stand at `runSetReady` while
naming a file no declaration was ever going to write — and the first thing to notice would
have been the first slot prelaunch, after a cohort had been assembled around it and an
operator had spent the one execution they were authorized.

**A runnable entry requires a run set that exists.** A slots-carrying build refuses
**`CE715`** unless it reached `runSetReady` *and* the authorization beside the declaration
is a real, read-only, non-reparse, 64-lowercase-hex file whose run set was verified against
this entry's own request digest. Pass `-Preflight -PreflightTarget runSetReady` to produce
one. A refusal here **withdraws the package it published**: a slots-carrying build has to
publish before its preparation can run, so a refusal that left the directory standing would
leave a sealed, seal-verifiable entry a manifest could name. Where no operator key is held,
`-PreparationOnly` builds a slots-carrying entry that states outright that it is **not**
cohort-ready (`CohortReady = $false`); that entry declares no run set, so a cohort naming it
runs the preparation from scratch and mints the authorization itself rather than trusting one.

**The cohort refuses it too, before anything starts.** `CohortRunner.Walk` checks every
entry's declared authorization in the same pre-walk pass that proves the model start bounds
— existence, single shared path across slots and reconciliation (and delivery, which is
optional), and 64-hex shape. It asks this only of an entry whose preparation already stands
at `runSetDeclared` or beyond: an entry starting from nothing mints its authorization *while*
declaring the set, so demanding one earlier would refuse every entry that had not run yet and
prove nothing. Only existence and shape are checked: the token's digest is sealed into the
run set's plan digest, and the reviewed prelaunch reproduces that plan only from the token
that was minted into it, so a *substituted* well-formed token is deliberately left for the
party that holds the plan to refuse rather than answered twice. The state record is read for
that one fact and is not authenticated in this pass, which holds no coordinator key: a record
that understates its state buys nothing, because the entry's very next act is to run its
coordinator, which loads the same record under its signing key.

**No write-enabled value is representable.** The four delivery capability fields are fixed
by `const` in the schema, and the builder re-checks each one after reading (`CE707`), so a
hand-edited request that never met the schema is refused a second time. `providerWriteBudget`
is deliberately read across the full integer range and *then* compared to zero, so a budget
of `1` refuses as "you asked to write" rather than as a malformed field.

**Models are derived, not named.** `DevPilot.AgentHarness` owns the supported-model list and
derives the generalist pair from it by family. The plan restates the pair it expects and the
builder refuses any disagreement (`CE705`), and refuses a specialist that is itself one of the
two generalists. It also refuses a plan whose models the reviewer configuration does not
configure (`CE706`). The consequence is that when the registry moves, a stale plan fails
loudly at build time instead of asking a slot for a model the agent no longer accepts.

The builder still starts nothing. It mints no launch token, no lease and no slot, and it
reads the model registry only to check names against it. The `slots` block it emits is a
*declaration* that the typed coordinator will later act on under an operator's own
authorization.

## The model-start bound is derived, never declared

The entry's `planEstimate` is the number a cohort budgets against, so the builder does not
get to invent it. After the coordinator request is written and digested, the builder invokes
`tools/New-ShadowModelStartBound.ps1` — the one reviewed derivation in the tree — as an
isolated child process over that exact file, and publishes the artifact it produces
**verbatim**. Nothing is recomputed here: a second arithmetic in a second file is a second
answer, and the cohort runner has no way to tell which one it is holding.

The producer reads the sealed request, re-hashes the reviewer configuration the request
pins, rebuilds each declared slot's argument vector with the same reviewed builder the run
will use, and multiplies the per-role attempt bounds out of the runner's own sources. It
starts no model: the vector is built with placeholder model identifiers, because counting
launches never needs to know which model makes them. For two slots against the shipping
runner that is **270 real model starts and 256 verifier assignments** — not two, which is
the slot count, and which is what an earlier version of this builder wrote down.

The published bound is then re-read and checked to bind *this* build: `kind` must be the one
`CohortRunner.ModelStartBoundKind` reads, `requestSha256` must equal the digest of the
request this entry emitted, `toolkitHead` must equal the head this entry pins, and the two
maxima must be present integers. `declaredSlotCount` must equal the slot count the builder
emitted. Anything else refuses under **`CE714`** and no entry is published — because the
alternative is an entry whose budget is a placeholder, which is exactly the under-declaration
`RequireSealedModelStartBounds()` exists to stop.

`planEstimate.modelStarts` and `planEstimate.verifierAssignments` are then taken *from* the
derived maxima, so "the estimate is an upper bound" holds by construction rather than by an
operator getting the arithmetic right. A preparation-only (v1) entry declares no slots, so
its derived bound is zero real model starts and it keeps estimating the run count it plans.

An operator may supply a bound derived earlier with `-BoundArtifactPath`, but it is an
*expectation*, not a substitute: the producer still runs, what gets published is always what
this build derived, and the supplied file has to state the same kind, request digest, toolkit
head, slot count and — above all — the same two maxima. Admitting a supplied artifact on its
bindings alone would admit one carrying the right labels over lowered maxima, and nothing
downstream could catch that: the estimate is taken *from* the maxima, so it can never
contradict them, and the cohort sizes its ceiling from the same file. The overspend would
surface only after the models had run. So supplying a bound proves a build reproduces a
number; it never asserts one.

## What it captures, and through what

Every read goes through the reviewed capture seam, in a closed plan that is declared before
the first read and checked after the last. Nothing interprets a raw REST response.

| Read | Tool | Exact arguments |
| --- | --- | --- |
| candidate identity | reviewed identity surface | — |
| live identity (again, at the end) | reviewed identity surface | — |
| repository | `repo_repository` | `action=get`, `project`, `repositoryNameOrId` = repository **id** |
| branch | `repo_branch` | `action=get`, `project`, `repositoryId` = repository **id**, `branchName` = short name |
| pull request | `repo_pull_request` | `action=get`, `project`, `repositoryId` = repository **name**, `pullRequestId` |
| changes | `repo_pull_request` | **not shaped here** — the live cycle's own request, from the one shared constructor: `action=get_changes`, `project`, `repositoryId` = repository **name**, `pullRequestId`, `top` = **1000** |
| changes with content | `repo_pull_request` | the same, plus `includeDiffs=true`, `includeLineContent=true` — a **distinct** request key |
| threads | `repo_pull_request_thread` | **not shaped here** — the live cycle's own request, from the one shared constructor: `action=list`, `project`, `repositoryId` = repository **name**, `pullRequestId`, `top` = **200** |
| changed file, sibling | `repo_file` | `action=get_content`, `project`, `repositoryId` = subject repository **id**, `path`, `versionType=Commit`, `version` = 40-hex commit |
| rule file | `repo_file` | the same shape, with `repositoryId` = the v3 section's authoritative rule repository **id**; one whole-file read is shared by multiple sections of the same repository/path/commit |

None of the three provider-list reads is shaped by this builder, and the reason is the same
for all of them. A replay answers the arguments it recorded and never falls through to a live
read, so a read the live cycle issues has to be captured **byte for byte** or the reviewer
stops mid-cycle on a read it can prove it needs and cannot get.

It happened twice. A corpus captured at `top=201` — the cap+1 instinct, which asks one above
the operator's ceiling so that overflow is observable, and which is right for a cap the
*builder* owns — met a cycle asking for `top=200`, and the slot died before its first model
start. The fix moved the thread vector to one shared constructor. The next shadow got past
the thread read, printed its scope, computed 100% pinned-source coverage, and died on the
change reads: `top=61` in the corpus against `top=1000` from the live convention planner.

So both vectors are built by shared constructors in `SourceTransport.ps1` —
`New-ReviewerThreadListRequest` and `New-ReviewerChangeListRequest` (the latter in both
variants, plain and `-IncludeDiffs`) — which the live agent and this builder both call. Each
page size is written down once; the shipping fact policy's `threads.maxThreads` and the
transport's own `ReviewerSourceChangeLimit` are checked against them when the agent loads.
A syntax-tree guard walks every `Invoke-AgentMcpTool` in the agent and fails the suite if any
`action=list` thread read or `action=get_changes` change read is assembled inline again.

Completeness is then **accounted** rather than probed:

- more threads than the operator's cap → `CE406`; more changed files → `CE402`;
- a list that reaches the page the reviewer asks for → `CE408` for threads, `CE409` for
  changes, because a full page is what a truncated list and a complete-and-exactly-full list
  both look like. A change set that states a continuation is `CE409` too, even below the
  page — *states*, not *carries*: every change response answers `nextSkip` and `nextTop`, and
  answers them `0` when there is no next page, so the values are read rather than the keys
  counted. A non-empty `continuationToken` or `nextLink`, a `nextSkip`/`nextTop` above zero,
  or a true `hasMoreChanges` refuses; a page offset that is not a number at all is `CE210`,
  because that is a response shape the wrapper does not produce;
- a request whose `maxThreads` is above that page → `CE113` at validation, since it declares a
  ceiling this build could never watch being crossed. It is a request-band code because the
  operator fixes it by editing the request; `CE408` means the subject itself is too large and no
  edit to the request helps. `maxChangedFiles` is range-bound to the change page for the same
  reason.

The two identity reads are the same question asked twice, and the second one is **declared in
the plan before the first read is issued**, carrying `DuplicateOf` naming the first. That is
what keeps the plan closed: a re-read issued outside the plan is a read nobody authorized,
and the corpus stores it once because both reads resolve to one request key.

The alias asymmetry in that table is deliberate and is the single most repeated historical
defect: `repositoryId` carries the repository **name** on the pull-request and thread tools
and the repository **id** on the branch and file tools, and `repo_repository` does not take
`repositoryId` at all. The builder writes each one from the request's typed field, so the
question never has to be answered again by hand.

Every response is stored in **the exact resource envelope and under the exact URI the
reviewer asks for**, byte for byte. A response that is the raw provider shape rather than
the reduced contract shape is refused (`CE203`) rather than normalized.

### The six shapes the wrapper contract does *not* share with raw REST

Each of these was found by running this builder against a real pull request, and each one
would have silently mis-assembled or refused a live entry. They are pinned by fixtures and
by sabotage cases, not by comment.

| Thing | Raw REST / natural assumption | Wrapper contract |
| --- | --- | --- |
| change collection | `changeEntries`, path at `entry.path` | `changes`, path at `entry.item.path` (`CE203` names the raw key) |
| change type | lower-case | capitalized (`"Edit"`), lower-cased once at the boundary |
| thread list | `{"value":[…]}` | a **bare JSON array** (the `value` / `threads` envelopes are also accepted, exactly as the reviewer accepts them) |
| embedded-resource URI | `ado://<org>/<project>/<repoId><path>` — which is the offline corpus-seal *record's* provenance URI | the repository-relative **path**, unchanged |
| PR status | `"active"` | `"Active"` — compared case-insensitively, as the reviewer has always compared it |
| target branch tip | equals the PR's `lastMergeTargetCommit` | on an active repository it moves ahead; only *resolution* is required, and the tip is recorded as `targetBranchTip` |

A seventh trap is not in the wrapper at all but in PowerShell: `$text | ConvertFrom-Json`
unrolls a top-level JSON array into its elements, destroying the array shape before any
contract check can see it. The parse boundary uses `-NoEnumerate` for that reason.

Two more names that are read from config rather than guessed: the reviewer's target ref is
`review.targetRefName` and is a full `refs/heads/…` ref, **not** a short `targetBranch`.

- **A replay never falls through to a live read.** A planned read whose recorded response
  is absent is a refusal, not a network call.
- **No write tool and no credential is reachable from a tool child.** The capture surface
  is the read-only contract; there is nothing to write with.
- The closing live-identity re-read shares the candidate read's request key, so it is one
  corpus resource read twice. The witness records `capture.identityReReads`.
- "Siblings" are baseline reads of the same path at the **common** commit, taken only for
  an `edit`, capped by `coverage.maxSiblingFiles`. There is no directory listing in the
  read ceiling, so a sibling is never a guess about what else is in a folder.

## What it publishes

An immutable directory, built in a `.staging-<guid>` sibling, inventoried, sealed and then
moved into place atomically, marked read-only, and re-verified **externally** afterwards:

```
<output.root>/
  entry/
    entry.json                 the cohort manifest entry, as the C# reader requires it
    coordinator-request.json   the typed coordinator request
    corpus-seal-recipe.json    the production offline corpus seal recipe
    identity-witness.json      candidate and live identity, and the re-read count
    config-validation.json     the validated reviewer config, targetRef exact
    census.json                the ordinal changed-path census and its spans
    changed-paths.json         the coordinator's exact changed-path contract
    rule-bundle.json           the pinned bundle, per-section commit and digest
    model-start-bound.json     the derived bound, verbatim from the shipping producer
  corpus/
    corpus-index.json          the payload index the typed stager verifies
    capture/…                  the flat start and end identity of the capture
    census/…                   the right-hand hunk census the seal derives spans from
    policy/…                   the pinned toolkit's source-transport policy
    files/… evidence/…         the payloads, at corpus-relative paths
  inventory.json               every published file, its digest and its length
  seal.json                    HMAC-SHA256 over the inventory, under the request's key
```

Corpus-relative paths are derived from the read's **role and global capture ordinal**
(`files/NNN.txt`, `evidence/siblings/NNN.txt`, `evidence/rules/NNN.txt`) and never from a
provider path, so a provider path can never traverse, collide or reach a reparse point.

The census carries **span evidence**, and both halves matter. The right-hand line spans are
extracted by the reviewer's own `Get-ReviewerSourceChangedSpans` over the diff variant —
never by a second reading of `lineDiffBlocks` written here — and each one is then checked
against the line count of the file this build captured at the source commit. The diff and the
file arrive on two independent reads, so nothing else compares them; a span past the end of
the file, one counting zero lines, or one overlapping the span before it makes the reviewer
slice bytes that are not the bytes the span names, and it is refused at `CE404`.

The package is **frozen read-only before the atomic rename**, not after it. Moving first and
freezing second leaves a window in which the destination exists, looks complete and is still
writable. A rename cannot be interrupted half-way, so freezing first makes "published" and
"read-only" the same instant. `inventory.json` and `inventory.seal` cannot inventory
themselves, so they are checked by name — leaving either writable would let an editor re-seal
a package they had changed. The published file set is compared to the inventory as a **set**,
not as a count: equal counts with different membership is exactly the shape of a substitution.

Nothing the coordinator writes lands inside the seal: the preflight's preparation output
root is `<output.root>.preparation`, a **sibling**, so an accepted entry is still byte-for-
byte the entry that was sealed.

The live MCP child is opened with `-Toolsets @('repos')` and with the reviewer's full
credential scrub (`AZURE_DEVOPS_EXT_PAT`, `SYSTEM_ACCESSTOKEN`, `COPILOT_GITHUB_TOKEN`,
`GH_TOKEN`, `GITHUB_TOKEN`) removed from its environment, restated explicitly rather than
inherited from a harness default. The tests assert both the toolset narrowing and every name
on that list.

The toolkit is required to be **clean as well as pinned**. `HEAD` naming the requested commit
is not the same statement as the assets on disk being that commit, and everything downstream
— the prompt-asset digest, the stage-contract digest, the capture surfaces themselves — is
read from the working tree. A tracked modification under `src/` or `tools/` is refused at
`CE213`. Untracked files are not: they change nothing that is read.

**Coverage is measured over the whole census, not over the paths that have content.** Every
right-hand read is mandatory and a failed one aborts the build, so measuring the covered
right-hand paths against the right-hand paths divides a set by itself: the answer is the
constant 100 and the operator's floor is a knob wired to nothing. Measured over the whole
census it says something real and subject-dependent — a pull request that is mostly deletions
carries content for only a small part of what it changed — and an operator may legitimately
refuse such a subject rather than review it on evidence that is mostly absent. A floor of `1`
accepts anything with content at all. The covered count itself is taken **row by row**, by
checking that each census row's own path resolved to a payload this build stored; a count
taken off the plan would restate the plan's cardinality and would still be right if every
payload had been filed under the wrong path.

**The sibling cap is a sample size, not a refusal.** The selector takes the first N eligible
edits in ordinal order, so a subject with more edits than the cap is reviewed on a smaller,
deterministic baseline rather than refused. The caps that do fail closed — `CE402` on changed
files, `CE406` on threads, `CE305` on bytes — bound counts the *provider* supplied, which is a
different statement about a different kind of surprise.

## The corpus seal recipe

The package carries `entry/corpus-seal-recipe.json`: the **production**
`reviewer-offline-corpus-seal-recipe`, the nineteen-key artifact
`Import-ReviewerCorpusSealRecipe` and `tools/Save-CorpusReplaySeal.ps1` read. It is not a
description of one — it is the thing itself, and the builder proves that by running the
sealer's own importer and planner over the staged corpus and the emitted recipe **before
publishing**, refusing at `CE805` if they do not accept it. An entry that would die at the
coordinator's `snapshotValidateOnly` state therefore never publishes at all.

Three payload classes exist for the seal and are staged from evidence this build already
holds, never from a second reading of a provider response:

| Payload | Where it comes from |
| --- | --- |
| `capture/start-identity.json`, `capture/end-identity.json` | The two live identity reads the builder already performs, written **flat** and under the exact field names the seal binds by — `pullRequestId`, `repositoryId`, `sourceCommit`, `targetCommit`, `commonCommit`, `iterationId`, `status`, `isDraft`. No alias, and no read timestamp: the end identity must be byte-comparable to the start, and a field that always differs would make drift undetectable. The end identity additionally states `matchesInitialCapture`. |
| `census/right-hand-hunks.json` | The span evidence in the sealer's canonical `newStart`/`newCount` hunk form — a restatement of the spans `Get-ReviewerSourceChangedSpans` already derived and this build already validated against the captured file, not a second mapping of `lineDiffBlocks`. |
| `policy/source-transport-policy.json` | The pinned toolkit's own `src/Agents/reviewer/source/v1/policy.json`, in the corpus so the seal is self-contained. A toolkit that ships none refuses at `CE803`. |

The recipe's `sourceTransport.expected` block is the artifact digest, block digest, coverage
digest and gate outcome the sealer will re-derive for itself. Both sides call the same
`New-ReviewerCorpusSealDerivedTransportArtifact`, which was **extracted from** the sealer
rather than restated here, so there is one derivation and the two cannot disagree.

Every entry carries a recipe, including a preparation-only v1 entry, which binds no models
and names the builder's own digest as its script hash. What makes an entry runnable is the
`executionPlan`; what makes it *sealable* is this recipe, and the two are separate claims.


`-Preflight` runs the **real** typed coordinator over the published request and requires
that it reached a named preparation state:

| `-PreflightTarget` | What it proves |
| --- | --- |
| `requestValidated` | The typed reader accepts every field, digest and path in the request. |
| `corpusValidated` | The typed C# corpus stager published and verified the corpus index. |
| `recipePlanned` | …and the stage-artifact recipe planned in full. |
| `snapshotValidateOnly` | …and the shipping sealer accepted the emitted corpus seal recipe. |
| `snapshotVerified` (default) | …and the offline corpus seal was sealed and re-verified. |
| `runSetReady` | The whole preparation, including the declared and verified run set. |

The default is `snapshotVerified` because that is the furthest state the **offline fixture**
reaches. It used to be `recipePlanned`, because the seal states needed an offline corpus seal
recipe this builder did not emit; it emits the production one now, so `snapshotValidateOnly`,
`snapshotSealed` and `snapshotVerified` are all reached from the package alone.

`runSetDeclared` is where the run set is declared, and the declaring tool re-reads the
**reviewer configuration as a full harness agent config** — schema version, prompt file, the
whole repo-specific shape. The suite's synthetic configuration carries only the fields the
builder itself reads, so the fixture stops there; a real operator configuration does not, and
a live build run with `-PreflightTarget runSetReady` walks the whole preparation — declared
run set, verified run set, `runSetReady` — with **zero models and zero provider writes**. The
launch authorization token is minted by the declaration itself, inside its publish
transaction, so reaching `runSetReady` needs no token the operator holds in advance; what a
token authorizes is the *launch*, and the builder never asks for one. The tests assert that
after a complete v2 build the token path the plan names still does not exist.

**Zero slots, models and tokens are consumed at any target.** The coordinator writes a
launch intent before every child, including the short read-only PowerShell tools that stage
a corpus; those consume nothing. A model run is the one that carries a slot, so the
preflight reads the intents back and refuses (`CE601`) if any names a slot or an expected
terminal artifact. A set identifier alone is **not** counted: once the run set is verified
the coordinator stamps its `setId` on every subsequent child, including the read-only status
probe, so counting it would call any `runSetReady` preflight a slot launch.

A v1 request generates a coordinator request with **no `slots` section**, so it cannot
authorize a slot state in the first place. A v2 request with an `executionPlan` does declare
two slots — and the preflight still launches none of them, because declaring a slot and
launching one are different acts and only the second needs an authorization the builder does
not have. The suite runs the whole preflight and cohort-acceptance proof **twice**, once for
each shape, and asserts zero slot intents both times.

## Refusals

Every refusal is a stable code and a sentence. The tool maps the hundreds digit to a
process exit code, because an exit code is one byte and the catalogue is not.

| Range | Exit | Refuses |
| --- | --- | --- |
| `CE1xx` | 2 | The request: schema, version, missing or extra field, unreadable file, BOM, path shape, toolkit head or ref drift, a `maxThreads` above the page the reviewer's own thread read asks for (`CE113`), or a v3 rule source crossing the subject's organization/project boundary (`CE114`). |
| `CE2xx` | 3 | The subject: pull request drift, draft, inactive; repository or project id **shape** mismatch; branch mismatch; the raw provider shape where the reduced contract shape is required (`CE203`); a change set that arrived as a singleton object (`CE210`); a toolkit working tree carrying tracked modifications (`CE213`). |
| `CE3xx` | 4 | The capture: a planned read never performed (`CE300`), a read performed but never planned or performed more times than planned (`CE301`), a MIME outside the allow-list (`CE302`), a resource URI that did not match exactly (`CE304`), a payload count outside its bound (`CE305`), a byte-order mark (`CE306`), a replay that has no record of a planned read and will not reach the provider for it (`CE307`), a write or a write authorization in a replay (`CE308`), an undeclared duplicate request key or a re-read that asks a different question (`CE309`), a rule section drifted from its pin (`CE310`). |
| `CE4xx` | 5 | The census and coverage: ordering, duplicates, path traversal, reparse points, the changed-file cap (`CE402`), the thread cap (`CE406`), a thread list that reaches the reviewer's own page and so cannot be proven complete (`CE408`), a change set that reaches the reviewer's own page or states a continuation (`CE409`), the byte cap, a right-hand path whose content was not stored or a content coverage under the declared floor (`CE403`), a span that runs past the end of the file it describes (`CE404`), an empty census (`CE407`), target ref or config mismatch. |
| `CE5xx` | 6 | The package: a staging or publish failure, a package that is not read-only including its own inventory and seal (`CE502`), an inventoried file whose bytes changed, an unlisted file, or a declared file that is absent (`CE503`), a reparse point (`CE505`), an inventory path that is not a plain relative path inside the package (`CE506`), a seal that does not authenticate. |
| `CE6xx` | 7 | The preflight: the coordinator did not reach its target (`CE600`), or it consumed a slot, a model or a launch token (`CE601`). |
| `CE7xx` | 10 | The execution plan: declared at a version that does not carry it (`CE700`), the wrong slot count or the wrong names in the wrong order (`CE701`), colliding slot state directories or terminal artifacts (`CE702`), a reviewer script that is absent or drifted from its declared digest (`CE703`), a model outside the shared registry (`CE704`), a generalist pair that is not the derived pair or a specialist that is one of the generalists (`CE705`), models the reviewer configuration does not configure (`CE706`), any delivery capability enabled or a non-zero provider write budget (`CE707`), reconciliation disabled or requiring a run count that is not the slot count (`CE708`), a slot count that is not the planned run count (`CE709`), a per-call timeout that outlives its slot (`CE710`), an output path outside the preparation root or a derived launch authorization that landed inside the sealed package (`CE711`), a model-start bound that is not a positive finite estimate (`CE712`), a bound that could not be derived or that does not bind this request (`CE714`), a slots-carrying entry with no declared run set and launch authorization to run under (`CE715`), and a request that names a launch authorization the builder derives for itself (`CE716`). |
| `CE8xx` | 9 | The corpus seal recipe: a live identity read carrying no value for a field the seal binds by name (`CE800`), a changed path with right-hand content but no right-hand span (`CE802`), a pinned toolkit shipping no source-transport policy (`CE803`), an emitted recipe the shipping sealer's own importer and planner will not accept (`CE805`), a recipe citing a payload or a change-set path this build did not stage (`CE806`). |

## Tests

`tools/Test-ShadowCohortEntryEvidence.ps1` — more than 400 checks offline and with `-IncludePreflight`;
no model, no network, everything in a temporary sandbox. The `-IncludePreflight` set ends with
one case that drives a build to `runSetReady` against a real run set declaration and then walks
the published entry through the shipping cohort runner, which is the only place the *published*
launch authorization and the *derived* one are shown to be the same file by construction.

- **Exact wrapper fixtures.** A synthetic but contract-exact replay snapshot for every tool
  in the table above, sealed the way a real snapshot is sealed. The fixtures answer in the
  live wrapper's shapes, so a green suite is evidence about the live contract rather than
  about shapes the fixtures invented for themselves.
- **One sabotage case per historical assembly incident.** A byte-order mark; a `source` and
  a `common` alias swapped; the raw Azure DevOps repository shape with `project` instead of
  `projectReference`; a change set written as a singleton object; a change set in the raw
  `changeEntries` shape; a change entry with a bare `path` instead of an `item`; a thread
  list answered as one bare object; an exact key present but null; a missing `get_changes`
  variant; a drifted resource URI; a resource served under the corpus-seal *provenance* URI
  form; a config target that is not the pull request's target; a census out of ordinal
  order; a read-only source mutated after publication. Each asserts the **exact code**, not
  merely a failure. Cases that must be *accepted* — a capitalized `changeType`, a
  capitalized PR status, either thread envelope — are asserted just as explicitly.
- **The output feeds the cohort runner without translation.** Beyond asserting every field
  the C# reader requires as published, the published `cohort-entry.json` is copied verbatim
  into a real `devpilot.shadow-cohort.manifest.v3` and handed to the **shipping**
  `ShadowRunCoordinator` under `--rebuild-index`, the one cohort verb that starts nothing.
  `CohortManifest.Load` validates the manifest and every entry field strictly before the
  runner discovers it has no journal to rebuild from, so that specific refusal — and only
  that one — is proof the entry was accepted.
- **Cross-implementation parity.** The prompt-asset digest this builder binds is compared
  against the coordinator fixture's independent implementation of the same digest.
- **v1 stays v1.** A v1 request and a v2 request without a plan are both asserted to emit no
  `slots` section and to derive a bound of zero real model starts while still estimating the
  runs they plan, so the compatibility claim is checked rather than assumed.
- **v3 separates capture from the pin.** A cross-repository fixture preserves a Unicode,
  CRLF whole file in the sealed corpus while checking two ATX sections against their own
  normalized UTF-8 pins. Missing, malformed, cross-organization/project, duplicate,
  ambiguous, tampered and wrong-request-key variants assert their exact refusal codes.
- **The bound is derived, and the derivation is reached.** The published bound's kind,
  request digest, toolkit head, per-role split and per-slot totals are all asserted against
  the *formula* — recomputed from the same four attempt factors the fixture runner declares
  — rather than against a number, so a builder that went back to writing the slot count down
  fails even though two slots is still two slots. A tampered kind, a foreign head, a foreign
  request, a missing or non-numeric maximum, an absent producer and a slot count the entry
  never declared each refuse as `CE714`. The preflight variants then run the *real*
  `ShadowRunCoordinator` **without** `--rebuild-index`, so `Walk()` and
  `RequireSealedModelStartBounds()` actually execute over the builder's own entry: the
  derived bound passes, an entry re-estimated at its slot count is refused against it, and a
  bound wearing an invented kind is refused outright.
- **The execution plan cannot be widened.** Roughly thirty sabotage cases: one slot, three
  slots, slots out of order or misnamed, colliding state directories or terminal artifacts
  case-insensitively, a drifted reviewer script digest, a model outside the registry, a
  generalist pair that is not the derived pair, a specialist that is one of the generalists,
  models the reviewer configuration does not configure, each delivery capability enabled in
  turn, a non-zero provider write budget, an authorization kind other than `PreviewOnly`,
  reconciliation disabled, a required run count that is not the slot count, a slot count that
  is not the planned run count, a per-call timeout that outlives its slot, an output
  directory escaping the preparation root, a launch authorization inside the sealed package,
  a fault-injection argument, an undeclared field, an omitted section, and a capability
  written as the string `"false"` — which PowerShell reads as `$true`. Each asserts the exact
  code. A slot appended to the published request afterwards is shown to break the pinned
  digest.
- **The plan agrees with the typed reader about names.** Every state directory, terminal and
  output name holding an embedded `..` is refused, because `SlotAuthorization.RequireLeafName`
  in the shipping reader refuses any component containing one — a name accepted here and
  refused there would only surface after the entry was sealed and frozen read-only.
- **A present-but-null plan is a catalogued refusal.** `"executionPlan": null` refuses under
  `CE700` and exits 8, rather than escaping as a parameter-binding error with no code.
- **The reviewer configuration is read as strictly as the reviewer reads it.**
  `review.verification.enabled` written as the string `"false"` or as `1` refuses under
  `CE211`, so the model-pairing check can never see a coerced `$true`.
- **Architecture and no-write.** No write tool, no credential and no model name is reachable
  from the capture surface; the schema carries no oracle-shaped field.
- **The seal contract is proven by the sealer, not by a restatement of it.** The offline
  happy path runs the shipping `tools/Save-CorpusReplaySeal.ps1 -ValidateOnly` over the
  builder-produced entry and requires exit 0 and no replay root written; the preflight then
  drives the real coordinator through `snapshotValidateOnly`, `snapshotSealed` and
  `snapshotVerified` for the versioned request shapes. Eight sabotage cases take that same
  entry, change exactly one thing, re-mint the corpus index so integrity is not what refuses,
  and require the sealer's own refusal: a recipe carrying an extra field, a recipe binding no
  start identity, a start identity naming `lastMergeSourceCommit` instead of `sourceCommit`,
  an end identity whose source commit drifted mid-capture, a census written in
  `lineDiffBlocks` form, a census written as one object rather than a list, a hunk moved one
  line off the span the changed file declares, and a reversed digest order. A pinned toolkit
  shipping no source-transport policy refuses at `CE803` at build time.
- **One changed file is built end to end.** A pull request that changes exactly one file is
  the shape where a census assembled through the pipeline stops being a list, so a separate
  build carries a single right-hand path and requires that the emitted census is still a JSON
  array and that the shipping sealer validates the entry.

Run the preflight section too with `-IncludePreflight`. It prefers an already-built
coordinator assembly so it never reaches a network; CI runs it after the coordinator suite,
which builds one from an empty offline feed.

## Known residuals

- **The offline fixture stops at `snapshotVerified`.** The declaring child re-reads the
  reviewer configuration as a full harness agent config, and the fixture writes only the
  fields the builder itself consumes, so `runSetDeclared` is out of reach in CI. Against a
  real operator configuration the whole preparation runs: a live build on this head reached
  `runSetReady` with zero models, zero provider writes and no token held in advance.
- **A right-hand path with no derived span cannot be sealed.** The seal shows the reviewer
  exactly the lines a span names, so a changed path that carries right-hand content but whose
  extractor derives no span refuses at `CE802` rather than sealing a file with nothing to
  point at. A subject in that shape is not buildable as a runnable entry, and that is the
  intended answer rather than a silent whole-file span.
- **The execution plan declares supervision timeouts it does not itself impose.** Only
  `supervisionGraceSeconds` travels in the coordinator request; per-call, slot and activity
  timeouts are read by the coordinator from the sealed qualification plan child result. The
  plan therefore *records* the envelope it expects in the entry's wall-clock estimate, and
  the two are reconciled where they meet rather than here.
- **Live Azure DevOps identity is not exercised in CI.** The suite is entirely offline, so
  the `live` capture mode is proven only against the reviewed capture seam, not against a
  live tenant. It has been exercised by hand against a real tenant, which is how the six
  contract divergences above were found; a fixture now pins each of them.
- **`changes` pagination is not consumed.** The wrapper answers `nextSkip`/`nextTop`
  alongside `changes` on every response, `0` meaning there is no next page. This builder reads
  one page under the live cycle's own `top` and
  refuses rather than paging silently: `CE402` above `coverage.maxChangedFiles`, and `CE409`
  when the response fills that page or states a continuation. So a subject larger than the
  declared cap, or one whose size cannot be established at all, is a refusal rather than a
  partial census. Paging would be a contract change, not a bug fix — and it would have to be
  made in the live cycle first, since the corpus may only record what the cycle asks for.
