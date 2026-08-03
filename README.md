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
schema/                      # JSON Schema for consumer configs
tools/                       # repo hygiene checks
tests/                       # Pester tests
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

`-PromotePreview` publishes the artifact's **delivery manifest** — the exact
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

- **A preview does not consume the commit.** It is recorded as *not delivered*,
  so you can still publish it. A delivered review closes that commit.
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
- **The summary is withheld until the comments it counts have landed.** Its text
  quotes how many findings were posted, so a summary written after a partial
  attempt and one written after the retry are *different* comments that
  fingerprint dedupe cannot collapse. It is deferred instead, and never written
  twice for the same review. A summary-only run (no `-EnableFindingComments`)
  posts immediately, since nothing it quotes is still moving.
- **A vote declined for a reason this run can undo stays open.** Declining
  because the findings did not post is retryable and leaves the vote unresolved;
  declining because the commit's own facts forbid the vote - a stale commit, a
  draft, or a recommendation the agent's own findings contradict - is final, so
  the PR does not stay pending forever.
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

Posted findings appear under **your** identity, since that is who the session is
authenticated as. That is why every write is opt-in.

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

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `./tools/Test-NoEmployerSpecifics.ps1`
and the agent `-DryRun` suite before opening a pull request.

## License

[MIT](LICENSE)
