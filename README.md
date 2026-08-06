# DevPilot Agents

A portable harness for **autonomous, wrapper-governed coding agents** driven by
GitHub Copilot CLI.

Agents run unattended on a developer machine, pick up work from a pull-request
host, reason about it, and make bounded changes. The design principle is that
the **model reasons; the wrapper decides**. A trusted PowerShell wrapper selects
and binds the work, owns all state, performs every external write, and validates
everything the model returns. The model never selects its own work and never
writes to the PR host directly.

> **Status: pilot.** One agent (`review-handler`) is implemented and running
> against Azure DevOps. Interfaces will change.

---

## Why a wrapper

Letting a model drive an autonomous loop directly means trusting it with
selection, authority, and state. This design deliberately does not:

| Concern | Owned by |
|---|---|
| Which PR to work on | Wrapper (deterministic selection) |
| What the agent may do | Wrapper (code-defined tool ceiling; config may narrow, never widen) |
| Every PR / pipeline write | Wrapper |
| Durable state and audit log | Wrapper |
| Reading code, reasoning, editing | Model |

The model's only channel back to the wrapper is a strict, nonce-bound result
marker. Anything else it prints is ignored.

---

## Repository layout

```text
src/
  DevPilot.AgentHarness/     # the shared, provider-agnostic module
  Agents/
    review-handler/          # an agent: script + prompt + fixtures
    reviewer/                # an agent: script + prompt
samples/                     # example configs for real repositories
tools/                       # repo hygiene checks and operator tooling
docs/                        # how to add an agent
```

**Consumers keep only a config file.** Nothing employer-, repository-, or
person-specific lives in this repo outside `samples/` — a CI check enforces that
(`tools/Test-NoEmployerSpecifics.ps1`).

---

## Quick start

```powershell
# 1. Load the harness (from a checkout; a published module is planned)
Import-Module ./src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1

# 2. Copy a sample config into the repository you want the agent to work on
#    e.g. <your-repo>/.github/copilot/agents/review-handler.config.json

# 3. Prove it works offline — no network, no Copilot process
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -DryRun `
    -ConfigFile <your-repo>/.github/copilot/agents/review-handler.config.json

# 4. First live cycle. Every mutating capability is OFF by default:
#    this analyses a PR and writes nothing.
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/review-handler.config.json `
    -OperatorAlias <your-alias>
```

The config's **location** tells the agent which repository to operate on, so it
must live inside that repository.

---

## The agents

| Agent | Watches | Does |
|---|---|---|
| `review-handler` | Your own open PRs | Finds reviewer feedback you have not answered, resumes the coding session where the code was written, makes the fix, replies, pushes, optionally requeues validation and sets auto-complete |
| `reviewer` | Other people's PRs | Reviews the diff and reports findings; optionally posts them as PR comments and casts a non-blocking vote |

### `reviewer` — a model with no write tools

The reviewer inverts the usual arrangement. The model is granted **no write tool
of any kind** — not even the PR-comment tool the `review-handler` uses, and not
`shell`, since an argument-prefix grant like `shell(git diff:*)` still admits
`git diff --output=<path>` and is therefore a file-writing primitive. It is also
granted **no outbound-network tool**: this agent reads private source, private
diffs and private review threads, and a `web_fetch` whose URL the model composes
is an exfiltration channel that an injected diff only has to ask for. The model
returns its findings as *structured data* in the result marker, the schema
bounds them, and the **wrapper** performs every write.

What that does and does not buy you, stated precisely:

- a successful prompt injection **cannot reach the host or the repository**:
  there is no tool to edit a file, run a command, post a thread, or cast a vote;
- everything the wrapper publishes is schema-bounded — severity is an enum, the
  anchor is checked against the PR's real change set, comment text is length-
  and character-limited, and the number of findings is capped;
- **but the wrapper still publishes text the model wrote.** An injected model
  cannot escape those bounds, and it can still emit a plausible, in-bounds
  finding — or an empty one with `recommendedVote: approve`. Structural
  validation cannot tell a genuine finding from a fabricated one.

That last point is why the reviewer is preview-first, and why publishing a
review you have actually read is a first-class mode rather than a re-run:

```powershell
# Offline validation
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -DryRun `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json

# 1. Preview one specific PR. Posts nothing; writes a .md to read and a .json beside it.
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> -PullRequestId 12345

# 2. Read the .md. If you agree, publish EXACTLY that review - no second model run.
./src/Agents/reviewer/Start-ReviewerAgent.ps1 `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> `
    -PromotePreview <state-dir>/previews/pr12345-<commit>-<stamp>.json `
    -EnableFindingComments -EnableSummaryComment

# Unattended alternative: review and post in one run. Faster, and nobody read it first.
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> -EnableFindingComments -EnableSummaryComment
```

For single-pass reviews, `-PromotePreview` publishes the artifact's **delivery manifest** — the exact
comment list, summary and vote that appeared in the Markdown you read — and
three things have to hold before any of it goes out. The artifact's HMAC seal
must verify against a per-user key that is *not stored in the artifact*; the
stored review must still parse under the same schema that bounded it and still
be bound to that PR and commit; and everything about to be posted must be a
**subset** of what you approved. Promotion may *drop* a comment that has since
become unpublishable. It can never add one.

The seal is the part that makes this more than ceremony. Re-validating a stored
review against a schema proves it is well-formed, not that it is unchanged —
the nonce and every self-describing field live inside the very file an attacker
would be editing, so checking the document against itself is tautological. The
key lives in the agent's state directory, DPAPI-protected to your user on
Windows. It defends against an artifact edited on disk; it does **not** defend
against an attacker who can already run code as you, who could equally well
post comments directly.

Running the agent twice, once to preview and once to post, does **not** give
you any of this: the second run is an independent model run with a fresh nonce
and may reach different conclusions.

The Markdown is what you actually read, so promotion refuses to run if that
document is missing or no longer matches the artifact beside it. Pass
`-AcceptUnverifiablePreviewDocument` to publish the sealed manifest anyway,
accepting that nothing can then show that what was published is what was read.

Other properties worth knowing:

- **A single-pass preview does not consume the commit.** It is recorded as *not
  delivered*, so you can still publish it. A delivered review closes that commit.
- **Delivery is tracked per capability.** Comments, the summary and the vote are
  recorded separately, so adding `-EnableApprovalVote` to a PR that already
  received comments still casts the vote instead of skipping the PR as done.
  A recorded success belongs to one specific review, not to the commit: a
  capability this run *attempted and failed* is never marked delivered on the
  strength of an earlier run's success, and a capability this run did not
  attempt only keeps an earlier success if that success was for this same
  review. Both rules err toward re-attempting, which fingerprints make a no-op.
- **An unfinished delivery is retried from its own sealed plan, not re-reviewed.**
  If some comments posted and others did not, the next cycle republishes that
  exact stored review rather than running the model again. A second model run is
  not deterministic: if it reported a smaller set of findings, everything it
  reported would already be on the PR, delivery would look complete, and the
  finding that failed the first time would never be mentioned again. The plan is
  written to state *before* the first ADO call, so a crash mid-delivery leaves a
  retryable plan rather than an invisible partial review.
- **The summary describes the review, not the delivery.** Its body quotes what
  was found and how much of it is *eligible* to post - never how much actually
  posted, and never a claim that anything was published. That is both honest
  (what lands depends on which write switches the run carried and on whether
  each thread write confirmed) and retry-stable, so fingerprint dedupe against
  the PR's own threads collapses a re-post instead of adding a second,
  differently-worded summary. An earlier design deferred the summary until the
  comments landed; that had no terminal path, so one permanently unpostable
  comment would have suppressed the summary forever. The eligible count itself
  comes from the **sealed** artifact, not from promotion's fresh re-scope of the
  change set, which could otherwise legitimately shrink and render a different
  body on a retry.
- **An artifact sealed by a different build of the agent is refused.** Comment
  text is rendered by the *running* script, so if a heading, footer or format
  string changed between builds, a comment the artifact already posted no longer
  fingerprints equal to the one about to be written and would be posted twice.
  The manifest is still intact in that case, so the seal cannot catch it - the
  recorded `scriptSha256` does. `-AcceptArtifactFromDifferentAgentVersion`
  overrides it. An unattended cycle **skips** such a PR rather than replaying or
  re-reviewing it: the plan is the only record of which findings still owe
  delivery, so discarding it could lose one, and re-reviewing under a changed
  comment format could duplicate one that already landed. A new commit
  supersedes the plan naturally.
- **A vote declined for a reason a retry could fix stays open; every other
  decline is final.** Only an actual comment-delivery gap - a failed post, or a
  post that did not confirm at its anchor - leaves the vote unresolved. Findings
  withheld on purpose, a run with comments switched off, a stale commit, a
  draft, and a recommendation the agent's own findings contradict are all
  permanent, so the plan is not retried forever over something no retry can
  change.
- **Nothing is written until the PR is re-read.** If the author pushed, or the
  PR became a draft or was completed while the model was running, the whole
  delivery is abandoned rather than partially applied.
- **Findings are published at exactly the location they name, or not at all.**
  A finding naming a file this PR does not touch, or carrying a file with no
  line (or a line with no file), is withheld and shown in the preview. There is
  no fallback to a PR-level comment: a relocated comment is a different comment,
  and retrying one produces duplicate noise.
- **An unreadable change set blocks publication.** Scoping fails *open* for a
  preview, because a human reads that and an empty preview would hide real
  findings; it fails *closed* for anything that posts.
- **Scheduling is least-recently-reviewed first**, so a repository with more
  open PRs than one cycle can review does not re-examine its newest few forever.
- It can never cast a `Rejected` vote; it refuses to vote when the findings that
  justify the vote were not posted; and a plain `Approved` requires *zero*
  findings.

#### Optional convention-specialist discovery

Repositories with path-gated convention packs can opt into a separate
discovery-only pass:

```powershell
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> -PullRequestId 12345 `
    -EnableConventionSpecialist -ConventionSpecialistModel claude-opus-5
```

The model must be named explicitly on the CLI or in
`review.conventionSpecialistModel`; there is no default. This specialist receives
sealed deterministic facts and commit/hash-verified matched convention sources,
not either generalist's output. Its strict `CONVENTION_REVIEW_RESULT_V1`
candidates are stored in separate sealed previews and are not merged, posted, or
used for voting. Failures are recorded as degraded specialist diagnostics without
changing the generalist review.

#### Optional cross-verification preview

Layer 5 can independently verify the two generalist passes plus convention
candidates without changing delivery:

```powershell
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> -PullRequestId 12345 `
    -Model claude-opus-5 -SecondPassModel gpt-5.6-sol `
    -EnableConventionSpecialist -ConventionSpecialistModel claude-sonnet-5 `
    -EnableVerificationPreview -ConventionVerifierModel gpt-5.6-sol
```

The wrapper preserves and seals every discovery artifact, normalizes candidates,
clusters exact and semantic duplicates deterministically, cross-assigns
generalist findings to the other model, and runs a named generalist verifier over
convention findings. Closed verifier outcomes can retain, lower severity,
deduplicate, or withhold; disagreement never becomes a vote. Input and decision
artifacts use separate HMAC domains and cannot be promoted as delivery manifests.
See [Cross-verification previews](docs/cross-verification.md).

#### Optional delivery gates (layer 6)

Layer 6 is a separate, fail-closed comment and approval-vote eligibility layer
over the sealed cross-verification preview above. It is off by default, and
nothing about it is reachable from repository config or PR content: enabling
any unattended capability requires an out-of-repo policy file, a matching CLI
switch, and a verified qualification artifact to agree, every run. Raw
two-pass delivery and raw `-PromotePreview` remain permanently preview-only
(discovery only, never posted) regardless of layer 6: the gate is the sole,
code-defined path by which an independent two-pass union can ever reach a PR
unattended.

```powershell
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> -PullRequestId 12345 `
    -Model claude-opus-5 -SecondPassModel gpt-5.6-sol `
    -EnableConventionSpecialist -ConventionSpecialistModel claude-sonnet-5 `
    -EnableVerificationPreview -ConventionVerifierModel gpt-5.6-sol `
    -GatePolicyFile C:\secure\gate-policy.json -GateQualificationFile C:\secure\qual.json `
    -EnableVerifiedCommentGate
```

A human can also promote exactly the sealed, human-promotable subset of a
gate decision - never more, never reworded, never at a raised severity - with
`-PromoteVerifiedPreview <path>`; it never casts a vote. See
[Delivery gates](docs/delivery-gates.md).

#### Evaluation harness and frozen corpus (layer 7)

Layer 6 will only open an unattended path when a signed qualification artifact
carries precision, recall, sample-count and false-approval numbers that clear
its code-defined floors. Layer 7 is where those numbers come from, and it is
built so that producing them can never become a way to skip them.

It measures and never delivers: no comment, no vote, no delivery
authorization, no promotion, no write path. The reviewer agent never loads it -
`Start-ReviewerAgent.ps1` contains no reference to the evaluation library, and
a test asserts that. Only `tools/` loads it, and only a human runs `tools/`.

Ground truth and claim verdicts are separate sealed artifacts on purpose. The
corpus is authored from pull requests alone and is structurally forbidden from
carrying any model output; blind claim verdicts live in their own artifact,
keyed by a content-derived key that carries no arm, model or pack, presented
through a field allowlist in a salted order. Partitions are frozen, grouped so
near-twin changes cannot straddle the split, and stratified across C#, tests,
deployment, settings, security, generated code, resources, service providers
and docs.

Three arms - generalist-only, multi-pass discovery, and independently verified -
are compared on identical pinned commits; a mismatched or stale pair is
rejected outright. Every qualification decision is an exact
`System.Numerics.BigInteger` Clopper-Pearson comparison with Bonferroni
adjustment over prespecified scopes, with a paired exact bound on recall
regression; no transcendental function appears on any metric path, because
those are not bit-identical across platforms. Zero-event vetoes always require
a denominator, and anything unknown, degraded, missing or partially adjudicated
fails closed.

```powershell
./tools/Import-ReviewerEvalCorpus.ps1 -ImportManifest <import.json> `
    -OutputPath <corpus.json> -StateDir <eval-state> -DeficitPath <deficit.json>

./tools/Invoke-ReviewerEvaluation.ps1 -CorpusFile <corpus.json> `
    -RunFiles <baseline.json>,<multipass.json>,<verified.json> `
    -AdjudicationFile <adjudication.json> -StateDir <eval-state> `
    -OutputPath <report.json> -ReportVersion 1
```

The report is sealed under evaluation-only HMAC domains and is structurally
rejected by both promotion paths. This repository ships **no real corpus**:
the checked-in fixtures are explicitly synthetic seed records that qualify
nothing, and the report emits machine-readable population deficits rather than
lowering a gate. See [Evaluation harness](docs/evaluation-harness.md).

#### Authoritative repository-source transport

`repoConventions.authoritativeSources` is an optional, versioned transport for
convention text stored in another repository in the same Azure DevOps
organization. The wrapper, not the model, verifies the repository GUID and
project, resolves each branch once, reads every configured path at that exact
commit, and accepts only bounded canonical base64 containing strict UTF-8
`text/plain` or `text/markdown`. The runtime context carries the decoded text
with organization/project/repository/path/branch/commit, byte-length, MIME, and
SHA-256 provenance. No resource URI is fetched or followed.

The source policy is fail-closed: version 1 requires exact keys, canonical
absolute `.md`/`.txt` paths, per-file and total byte limits, and optional
`expectedSha256`/`expectedByteLength` pins. A failed source read aborts only a
fresh review; it uses a dedicated MCP session after pending-delivery retries, so
it cannot strand an already sealed review. Source repositories and branches
must be trusted to define conventions for the reviewed repository, but their
text still cannot alter the bound PR, tools, nonce, schema, or output contract.

This transport targets the MCP embedded-resource shape verified with Agency
`2026.7.31.2`. Additive or malformed resource fields fail closed rather than
being ignored. It converts only configured wrapper-fetched sources; model-side
`repo_file get_content` may still be resource-shaped and unusable. Also,
`permissions.allowTools` must contain at least one mapped read-only permission:
an empty list is rejected rather than falling back to CLI-default discovery.
`samples/reviewer-ado.config.json` contains the generic contract.

#### Path-gated convention packs

`repoConventions.conventionPacks` is a separate, versioned convention catalog for
a later specialist reviewer. Layer 2 computes and saves a context plan before any
model launch, but deliberately does **not** add the plan or its sources to either
existing generalist pass. The catalog reuses the authoritative source transport's
repository, commit, MIME, hash, and decoded-byte checks without sharing its
generalist runtime-context destination.

Selection runs in a dedicated, repos-only per-PR MCP session opened only after
pending delivery retries. Target/change/PR/source reads never share the review MCP
session that owns later candidates and writes, and the isolated session closes in
a `finally` path. Selection is deterministic: changed paths use `/` separators, one leading slash
is ignored, Windows `\` separators are normalized, and matching is ordinal
case-insensitive because the reviewer is Windows-only. Globs support segment-local
`*` and `?`, plus `**` only as a complete segment. Character classes, braces,
extglobs, escaping, absolute/traversal paths, consecutive `**`, and a bare `**`
are rejected. A rename considers both old and new paths; a delete considers the
deleted path. Generated files are never hidden by a heuristic: they select only
the packs whose explicit globs match them.

Overlapping packs are retained and ordered by ascending `priority`, then exact
pack name. Paths and source requests are deduplicated within the plan; the same
source used by multiple selected packs is conservatively charged to every pack.
Unmatched packs resolve no sources. Repository-local convention files are read
from a twice-checked target-branch commit, never from author-controlled PR source
content.

Each pack's `maxBytes` covers decoded source bytes plus the exact serialized
source-provenance descriptor. Startup computes that requirement from declared
source maxima, exact configured provenance, and the longest allowed MIME; the
accepted boundary therefore fits at runtime exactly. Matched-path/glob routing evidence is persisted and
byte-counted separately, not treated as convention context. The code-defined
total convention-context cap is 131072 bytes. Exceeding either context cap fails
that PR's plan closed before its model launch; no source or rule is silently
truncated. The saved plan records selected and withheld packs, matched paths and
globs, source trust tiers, repository/path/ref/commit/hash/MIME/byte provenance,
the pinned change-set digest, and exact byte counts. See
[docs/convention-packs.md](docs/convention-packs.md) and the
preview-only `samples/azureux-bpm-convention-packs.preview.json` replay profile.

An authoritative source may name a `section` - the exact ATX heading of the
governing rule - so that a large engineering-guidance document routes by rule
rather than as a whole file. Without it a 60 KB rule document either exceeds its
per-source cap, which fails the pack and means the rule silently never reaches
the reviewer, or consumes an entire pack budget on its own.

#### Sealed source transport (layer 8)

**The model is given no working file-read tool. It is given the file's bytes.**

On a real Azure DevOps MCP host, `get_content` answers with an embedded resource
whose payload is a base64 `blob`. The wrapper decodes that correctly; a model
transcript does not carry binary resource payloads, so the model receives an
empty result - no text, no error, no way to distinguish "empty file" from "read
failed". The remaining channel, the change-set tool with line content, is a
single 1.6 MB tool result for a ten-file PR. The visible effect was a confident
review of files nobody had read.

So the wrapper reads them. It derives each changed file's right-hand line spans
from the diff, reads the bytes itself at the exact source commit, cuts whole-line
slices with a context radius, hashes each slice, and injects a sealed, bounded
block. Nothing about the model's tool grant changes; it gains content, not
capability.

The block opens with a **content accounting table** naming every changed path and
whether its source arrived (`delivered`, `partial`, `omitted`, with a closed
reason set). Both prompts bind the model to it: an `omitted` path may not be
reported on, cleared, or counted as reviewed — unless its reason is
`noChangedSpans`, the one reason that means the pull request itself says the path
holds no added or edited text. Every other omission reason means the source
content could not be established, and those files count against coverage. Below a
configured coverage
floor the PR is **not
reviewed at all** - no preview, no comments, no vote - and the
preview a human reads states the coverage and names the files whose source never
arrived. See [docs/source-transport.md](docs/source-transport.md).

Posted findings appear under **your** identity, since that is who the session is
authenticated as. That is why every write is opt-in.

#### Offline snapshot replay (layer 9)

A pull request moves on. Once it has, the evidence that produced a particular
review is gone, and "we fixed the miss" is an assertion nobody can check.

Replay records the reads one cycle made and re-runs the **whole** stack against
those exact bytes - transport, packs, facts, both generalist passes, the
specialist, cross-verification, the gate and every preview - with no repository
contacted. It is served at the one seam every read goes through, so the layers
above it are unchanged and still apply their full hostile-input validation to
replayed payloads.

It is permanently preview-only: every write and gate switch and both promotion
paths are refused at startup, the authorization is forced to `PreviewOnly`, the
artifacts are sealed under a separate key domain so promotion cannot verify
them, and replay state lives apart from live state. The model's grant is
narrowed to `read`, because a model tool would reach the host through the CLI's
own credentials rather than the replayed session - so a replay is a stated
*lower bound* on a live run, not a reproduction of one. See
[docs/replay-snapshots.md](docs/replay-snapshots.md).

### Two passes, two models

A single model's coverage of real defects is both incomplete and *idiosyncratic*
— two models do not miss the same things. `-SecondPassModel` reviews every PR
twice, with a different model each time, and previews the **union**:

```powershell
./src/Agents/reviewer/Start-ReviewerAgent.ps1 `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> `
    -Model claude-opus-5 -SecondPassModel gpt-5.6-sol
```

Measured on nine live pull requests carrying thirteen defects that were then
verified by hand against the source:

| Reviewer | Defects found |
|---|---|
| best single model | 10 / 13 |
| second-best single model | 5 / 13 |
| the two together | **13 / 13** |

The pairing beats either model not because the second one is good but because it
is *different*: the five it found included two the first missed entirely, and it
missed six the first caught. Pick a partner that fails differently, not one that
scores well.

How it works, and why it is arranged this way:

- **The union is discovery-only in this layer, permanently.** The passes do not
  cross-review or independently verify each other's findings. With
  `-SecondPassModel`, finding comments, summary comments, approval votes and
  raw `-PromotePreview` are all rejected before publication, and stay that way
  even with layer 6 (delivery gates) enabled - there is no config or CLI
  override, and no reordering, that lets the raw union itself post. The only
  way an independently-verified union reaches a PR unattended is through layer
  6's own gate write paths (comments/suggestions/approval,
  `-PromoteVerifiedPreview`), which mint their own short-lived, PR/commit/
  coverage-bound typed authorization from a sealed cross-verification decision
  - see [Delivery gates](docs/delivery-gates.md).
- **The passes are independent.** Each gets its own nonce, is validated against
  the marker schema on its own, and is bound to the PR and commit on its own.
  Neither sees the other's output — a second model shown the first one's
  conclusions stops being a second sample and starts agreeing, which would erase
  exactly the disagreement the pass was added to surface.
- **The wrapper merges, not a model.** Findings are unioned; a finding both
  passes report is deduplicated on its anchor and its normalised text, and keeps
  the *more severe* of the two grades. Two differently worded findings on one
  line are kept as two: no similarity heuristic can distinguish "the same point,
  said differently" from "two distinct bugs on one line", and dropping one to
  save a duplicate comment would lose a real finding.
- **The union is still filtered as if it could be posted.** The per-PR cap, the
  severity threshold and the change-set anchor check all apply before preview,
  unchanged, so the discovery artifact reflects the eventual delivery shape.
- **A plain approval requires *every* pass to approve.** The merged
  recommendation is the least approving one offered — an unrecognised value
  collapses it to "no vote". In the benchmark the single worst outcome was a
  confident approval of a PR that broke two APIs, and it was the partner model
  that caught it.
- **A pass that fails degrades loudly.** If one pass produces nothing usable the
  findings that *did* arrive remain in the preview — a real defect is useful
  discovery however many models saw it — the sealed manifest records
  `passesRequested`/`passesCompleted`, and **no vote is available**.
- **Cost and wall-clock roughly double.** Each pass is a full model run with its
  own `-CycleTimeoutSeconds` budget.

Both models must be named explicitly: pairing a chosen model against "whatever
the CLI defaults to today" is not reproducible, and naming the same model twice
is refused outright — it doubles the cost to miss the same things twice.

---

## Running unattended

An agent loop spends most of its life waiting on a model, so it wants to run
detached — but a detached process you cannot question is not supervision, it is
hope. `tools/Invoke-AgentControl.ps1` covers the three things an operator
actually needs: start it, find out what it is doing, take it back.

```powershell
$state = "$env:LOCALAPPDATA\DevPilot\Reviewer\my-repo"

# Start it. Nothing here grants a capability the agent's own parameters do not:
# everything after -AgentArguments is passed through untouched.
./tools/Invoke-AgentControl.ps1 -Action start -Name my-reviewer -StateDir $state `
    -AgentScript ./src/Agents/reviewer/Start-ReviewerAgent.ps1 `
    -AgentArguments @(
        '-ConfigFile', 'C:\repos\my-repo\.github\copilot\agents\reviewer.config.json',
        '-OperatorAlias', 'myalias',
        '-StateDir', $state,
        '-Model', 'claude-opus-5', '-SecondPassModel', 'gpt-5.6-sol')

./tools/Invoke-AgentControl.ps1 -Action status -Name my-reviewer -StateDir $state
./tools/Invoke-AgentControl.ps1 -Action tail   -Name my-reviewer -StateDir $state
./tools/Invoke-AgentControl.ps1 -Action stop   -Name my-reviewer -StateDir $state

# Survive a reboot. Starts the agent the same way, so status/tail/stop still work.
./tools/Invoke-AgentControl.ps1 -Action install -Name my-reviewer -StateDir $state -AgentScript ... -AgentArguments ...
```

`status` answers "is it alive and what has it decided" together, because the
first question is rarely the interesting one: it prints the process and its
children, then the last few records from the agent's own structured cycle log,
how many reviews are sitting unread, and how many cycles failed.

Three details are worth knowing rather than discovering:

- **`stop` is safe at any moment, including mid-review.** The single-writer lock
  is released by the OS when the process dies, state writes are atomic, and an
  interrupted cycle is discarded and re-attempted. A cycle killed *after* it had
  already posted does not double-post, because posted comments are recognised
  from the pull request itself rather than from local state.
- **`stop` kills the model process too.** Terminating only the parent leaves the
  model running, holding no lock, spending a budget nobody is watching.
  Descendants are found by parent process id — never by process name, which
  would match unrelated work in another window.
- **A recorded process id is checked against its launch instant.** Windows reuses
  process ids; a stale record from a machine that lost power will eventually name
  a live process that is something else entirely, and `stop` would kill it.

For unattended operation the preview-first mode is the point, not a limitation:
leave the write switches off, let it accumulate reviews you can read, and promote
the ones you agree with. `Invoke-AgentControl.ps1` says so at start time — it
warns when the arguments it is about to pass through would let the agent post
without anyone having read the result.

---

## Safety model

Non-negotiable, and enforced in code rather than prose:

- **Code-defined tool ceiling.** Config can narrow it; nothing can widen it.
- **Mandatory denies.** PR-write and pipeline-write are denied to the model
  unconditionally — the wrapper performs those itself. The `reviewer` agent
  extends this to *every* write, including PR comments, so the model it runs has
  no write tool at all.
- **Every mutating capability is a separate switch, defaulting OFF.** Pushing
  requires two independent flags.
- **Protected branches** (`main`, `master`, `dev`, `release/*`) are rejected in
  the wrapper before push tooling is granted, not merely discouraged in a prompt.
- **All PR text is untrusted input.** Comment bodies are never interpolated into
  the model's instructions; the prompt carries a structured metadata digest
  instead. An agent that *chooses* to read a thread through a read tool gets
  that text as tool output, which the prompt's ground rules classify as data.
- **Writes are verified by re-reading state**, never by trusting a response —
  some hosts confirm writes in prose, and parsing that as JSON throws *after*
  the write has already landed.
- **`-DryRun` self-checks are mandatory** and run offline.

---

## Extending

Adding an agent means adding a folder under `src/Agents/`, containing a wrapper
script, a cycle prompt, and any fixtures. The harness supplies everything else.

See [`docs/adding-an-agent.md`](docs/adding-an-agent.md).

---

## Known limitations

- **Azure DevOps only, today.** A provider abstraction for GitHub is designed
  but not implemented. Thread resolution, auto-merge, and validation-run lookup
  differ enough between hosts to need real adapters.
- **The local-validation tool ceiling is code-defined.** .NET and MSBuild repos
  work out of the box; adding another build ecosystem (npm, cargo, gradle)
  requires a toolkit change and a security review — deliberately, since the
  ceiling is a security boundary.
- **Telemetry is local JSONL.** Central aggregation and a dashboard are planned.
- **An unattended `reviewer` posting run is not injection-proof.** The model
  cannot write anything itself, but the wrapper publishes text the model wrote.
  Schema validation bounds that text; it cannot establish that a finding is
  genuine. Where that matters, preview and then `-PromotePreview` a review a
  human has read.
- **The reviewer judges from the diff.** It has no build, no tests and no
  execution, deliberately — every build tool it gained would be a tool an
  injected prompt could aim at the host. Whole classes of defect are therefore
  outside what it can find, and it is an addition to human review, not a
  replacement for it.
- **A second pass raises coverage; it does not establish correctness.** Two
  models that miss different things find more between them, but two models can
  still be wrong the same way, and the merge unions their findings rather than
  cross-examining them — a false positive from either pass survives to the
  preview. Nor is the published pairing permanent: it was measured on one
  repository at one point in time, and a model release invalidates it. Re-run
  the comparison rather than inheriting the recommendation.
- **The change-set guard validates files, not lines.** A finding must name a
  file the PR changes, but within that file the model can name any line. Right-
  side changed-line ranges are not yet parsed.
- **Withholding cross-file findings is a policy, not a free win.** A changed
  caller that breaks an untouched implementation is a real defect, and the
  agent will withhold a finding anchored in the untouched file rather than
  relocate it. The intended shape is to anchor on the changed causal line and
  describe the cross-file consequence there.
- **Candidate selection sees the first 100 active PRs.** Scheduling within that
  slice is least-recently-reviewed first; pagination beyond it is not
  implemented. `-PullRequestId` reaches any single PR directly.
- **`WaitingForAuthor` is a real blocker in most ADO branch policies**, and
  there is no policy yet for neutralising a stale `-5` after the author pushes
  a fix. Leave `-EnableApprovalVote` off unless you want that.
- **Artifact sealing does not survive a compromised account.** The signing key
  is DPAPI-protected to your user; an attacker who can run code as you can sign
  anything — but could equally well post comments directly.
- **The delivery-gate approval vote (layer 6) is unconditionally closed today.**
  Its GitHub-only capability reads (required checks, review-dismissal-on-push)
  are implemented and tested, including against a live read-only PR, but this
  script still restricts `config.provider` to `AzureDevOps`, which the gate
  always reports as lacking every capability it needs. Comment/suggestion
  gating has no such restriction. See [docs/delivery-gates.md](docs/delivery-gates.md).
- **A gate qualification's signature proves it was not edited after signing,
  not that its corpus numbers are honest.** Who may run
  `tools/New-ReviewerGateQualification.ps1` and publish its output is an
  organizational boundary, not a cryptographic one.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `./tools/Test-NoEmployerSpecifics.ps1`
and the agent `-DryRun` suite before opening a pull request.

## License

[MIT](LICENSE)
