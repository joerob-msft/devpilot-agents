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

`src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v1.json`,
`schemaVersion: 1`, `kind: reviewer-cohort-entry-evidence-request`. Strict throughout —
`additionalProperties: false` on every object, so a misspelled field is a refusal rather
than a silently ignored intention.

| Section | What it fixes |
| --- | --- |
| `correlationId` | One id carried into the coordinator request, the audit and every child log. |
| `toolkit` | Repository root, the exact head commit, and the ref that head must be on. |
| `subject` | Organization, project, repository **id** and **name**, pull request id, and the target ref the entry is claimed against. |
| `reviewer` | Config path, repository path, operator alias, PowerShell path, child timeout, planned run count, run-set key. |
| `ruleBundle` | Where the pinned rules come from, the declaration digest, and each section's path, commit and digest. |
| `capture` | `replay` or `live`, the replay root, snapshot name and manifest digest, the agency path, and the request timeout. |
| `coverage` | Maximum changed files, file bytes, sibling files and threads, and the minimum changed-path coverage percent. |
| `output` | Where the package is published, its entry id, its cohort ordinal, and the seal key. |

Both `subject.repositoryId` and `subject.repositoryName` are required, because the wrapper
contract uses **both** and does not use them interchangeably — see the alias table below.

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
| changes | `repo_pull_request` | `action=get_changes`, … `top` = `maxChangedFiles` **+ 1** |
| changes with content | `repo_pull_request` | the same, plus `includeDiffs=true`, `includeLineContent=true` — a **distinct** request key |
| threads | `repo_pull_request_thread` | `action=list`, `project`, `repositoryId` = repository **name**, `pullRequestId`, `top` = `maxThreads` **+ 1** |
| changed file, sibling, rule section | `repo_file` | `action=get_content`, `project`, `repositoryId` = repository **id**, `path`, `versionType=Commit`, `version` = 40-hex commit |

The `+ 1` on the two capped reads is not an off-by-one. A provider asked for exactly the cap
answers exactly the cap when there are more, so a count equal to the cap is indistinguishable
from a complete answer — which is how a truncated census once looked whole and admitted a
subject larger than the operator authorized. Asking for one above the cap makes the
difference observable: above the cap is `CE402`/`CE406`, at the cap is genuinely all there is.

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
    identity-witness.json      candidate and live identity, and the re-read count
    config-validation.json     the validated reviewer config, targetRef exact
    census.json                the ordinal changed-path census and its spans
    changed-paths.json         the coordinator's exact changed-path contract
    rule-bundle.json           the pinned bundle, per-section commit and digest
    model-start-bound.json     the signed no-model bound and the verifier bounds
  corpus/
    corpus-index.json          the payload index the typed stager verifies
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

## The no-model preflight

`-Preflight` runs the **real** typed coordinator over the published request and requires
that it reached a named preparation state:

| `-PreflightTarget` | What it proves |
| --- | --- |
| `requestValidated` | The typed reader accepts every field, digest and path in the request. |
| `corpusValidated` | The typed C# corpus stager published and verified the corpus index. |
| `recipePlanned` (default) | …and the stage-artifact recipe planned in full. |
| `runSetReady` | The whole preparation, **including** the offline corpus seal. |

The default is `recipePlanned` because that is the furthest state a cohort-entry package
reaches **from its own inputs**. The next state, `snapshotValidateOnly`, additionally
requires an *offline corpus seal recipe* — a nineteen-key artifact owned by the reviewer's
acquisition path, not by this builder. An operator who has one passes
`-PreflightTarget runSetReady`. Defaulting to `runSetReady` would make this tool claim a
proof it cannot produce, so it does not.

**Zero slots, models and tokens are consumed at any target.** The coordinator writes a
launch intent before every child, including the short read-only PowerShell tools that stage
a corpus; those consume nothing. A model run is the one that carries a slot, so the
preflight reads the intents back and refuses (`CE601`) if any names a slot, a set or an
expected terminal artifact. The generated request deliberately carries **no `slots`
section**, so it cannot authorize a slot state in the first place.

## Refusals

Every refusal is a stable code and a sentence. The tool maps the hundreds digit to a
process exit code, because an exit code is one byte and the catalogue is not.

| Range | Exit | Refuses |
| --- | --- | --- |
| `CE1xx` | 2 | The request: schema, version, missing or extra field, unreadable file, BOM, path shape, toolkit head or ref drift. |
| `CE2xx` | 3 | The subject: pull request drift, draft, inactive; repository or project id **shape** mismatch; branch mismatch; the raw provider shape where the reduced contract shape is required (`CE203`); a change set that arrived as a singleton object (`CE210`); a toolkit working tree carrying tracked modifications (`CE213`). |
| `CE3xx` | 4 | The capture: a planned read never performed (`CE300`), a read performed but never planned or performed more times than planned (`CE301`), a MIME outside the allow-list (`CE302`), a resource URI that did not match exactly (`CE304`), a payload count outside its bound (`CE305`), a byte-order mark (`CE306`), a write or a write authorization in a replay (`CE308`), an undeclared duplicate request key or a re-read that asks a different question (`CE309`), a rule section drifted from its pin (`CE310`). |
| `CE4xx` | 5 | The census and coverage: ordering, duplicates, path traversal, reparse points, file, sibling, thread and byte caps, a span that runs past the end of the file it describes (`CE404`), an empty census (`CE407`), coverage floor, target ref or config mismatch. |
| `CE5xx` | 6 | The package: a staging or publish failure, a package that is not read-only including its own inventory and seal (`CE502`), an inventoried file whose bytes changed, an unlisted file, or a declared file that is absent (`CE503`), a reparse point (`CE505`), an inventory path that is not a plain relative path inside the package (`CE506`), a seal that does not authenticate. |
| `CE6xx` | 7 | The preflight: the coordinator did not reach its target (`CE600`), or it consumed a slot, a model or a launch token (`CE601`). |

## Tests

`tools/Test-ShadowCohortEntryEvidence.ps1` — 148 checks offline, 157 with `-IncludePreflight`;
no model, no network, everything in a temporary sandbox.

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
- **Architecture and no-write.** No write tool, no credential and no model name is reachable
  from the capture surface; the schema carries no oracle-shaped field.

Run the preflight section too with `-IncludePreflight`. It prefers an already-built
coordinator assembly so it never reaches a network; CI runs it after the coordinator suite,
which builds one from an empty offline feed.

## Known residuals

- **`runSetReady` needs a seal recipe this builder does not emit.** The offline corpus seal
  recipe is a separate producer (`src/Agents/reviewer/CorpusSeal.ps1`), whose
  `sourceTransport` expectations are *converged* by probing the planner rather than
  computed. Until a cohort entry emits one, the honest default target is `recipePlanned`.
- **Live Azure DevOps identity is not exercised in CI.** The suite is entirely offline, so
  the `live` capture mode is proven only against the reviewed capture seam, not against a
  live tenant. It has been exercised by hand against a real tenant, which is how the six
  contract divergences above were found; a fixture now pins each of them.
- **`changes` pagination is not consumed.** The wrapper answers `nextSkip`/`nextTop`
  alongside `changes`. This builder reads one page under an explicit `top` and refuses at
  `CE402` above `coverage.maxChangedFiles` rather than paging silently, so a subject larger
  than the declared cap is a refusal rather than a partial census. Paging would be a
  contract change, not a bug fix.
