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
tools/                       # repo hygiene checks
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

# Target one of your PRs explicitly:
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/review-handler.config.json `
    -OperatorAlias <your-alias> -PullRequestId 12345
```

The config's **location** tells the agent which repository to operate on, so it
must live inside that repository.

---

## The agents

| Agent | Watches | Does |
|---|---|---|
| `review-handler` | Your own open PRs | Finds reviewer feedback you have not answered, resumes the coding session where the code was written, makes the fix, replies, pushes, optionally requeues missing, failed, stale, or expired validation (even when no commit was needed), and sets auto-complete |
| `reviewer` | Other people's PRs | Reviews the diff, reports findings, and assesses human review comments; optionally posts findings, replies in-place, and casts a non-blocking vote |

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

The reviewer can also assess existing human-authored ADO comments in place.
For an active thread whose latest relevant comment is human-authored, it may
verify, justify, clarify, support, or refute the comment against the diff and
repository context. Agent, bot, and system responses are never targets. Replies
are opt-in with `-EnableThreadReplies`, bound to the exact human comment ID,
previewed and sealed with the rest of the review, and re-checked immediately
before the wrapper posts them.

### Repository review skills

A consumer can delegate review analysis to repository-owned skills without
granting the model any additional tools:

```json
"reviewSkills": {
  "primary": ".github/skills/code-reviewer/SKILL.md",
  "security": ".github/skills/sdl-security-review/SKILL.md",
  "securityMode": "auto"
}
```

Both paths must be repository-relative Markdown files under `.github/skills`.
The primary skill supplies the repository's review process and linked reference
material. Security mode is `off`, `auto`, or `always`; `auto` applies the
security skill only to security-sensitive changes.

Skill guidance is subordinate to the reviewer's fixed cycle contract. The model
may read and apply analysis guidance, but it still cannot ask an interactive
question, run shell commands, edit files, post comments, or vote. The V3 result
marker carries bounded flat objects for scope, applied guidance, verified
strengths, rollout risk, validation, SDL results, and recommendation rationale.
The trusted wrapper—not the model—renders the recommendation banner, count and
findings tables, status rows, headings, and footer as deterministic Markdown.
It also records whether the configured finding cap was reached and how many
additional actionable findings the model omitted, so operators can tune the cap
without removing the runaway safeguard. The wrapper owns every write.

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
    -EnableFindingComments -EnableThreadReplies -EnableSummaryComment

# Unattended alternative: review and post in one run. Faster, and nobody read it first.
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/reviewer.config.json `
    -OperatorAlias <your-alias> `
    -EnableFindingComments -EnableThreadReplies -EnableSummaryComment
```

### Console output and event stream

Both `reviewer` and `review-handler` expose the same
`-OutputMode Auto|Compact|Detailed|Json` contract:

- **`Auto`** (default) uses a single bounded, cursor-refreshed phase line on an
  interactive ANSI-capable terminal. It falls back to `Compact` when stdout is
  redirected, the terminal is narrow, or cursor rendering is unavailable.
- **`Compact`** emits bounded cycle summaries. Routine candidate exclusions are
  aggregated by reason instead of printing one line per pull request.
- **`Detailed`** retains individual candidate skip and delivery diagnostics.
- **`Json`** writes only JSON Lines events to stdout. Human status text is
  suppressed; failures are represented as error events and still preserve the
  process exit code.

```powershell
# Bounded output for a service log
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -OutputMode Compact `
    -ConfigFile <path> -OperatorAlias <alias>

# Full operator diagnostics
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -OutputMode Detailed `
    -ConfigFile <path> -OperatorAlias <alias>

# Feed an external monitor
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -OutputMode Json `
    -ConfigFile <path> -OperatorAlias <alias> > reviewer-events.jsonl
```

Every mode also writes a bounded, process-isolated diagnostic event stream
under the agent state directory:

```text
logs/events/reviewer/<instanceId>.jsonl
logs/events/review-handler/<instanceId>.jsonl
```

Each stream rotates at 10 MiB with five rotated files. The twenty most recent
instance streams per agent are retained. Existing cycle metadata logs and
failed-cycle transcripts remain unchanged.

The shared event envelope is:

```text
schemaVersion, agent, instanceId, processId, timestamp, sequence, eventType, level,
cycleNumber, pullRequestId, sourceCommit, data, message
```

`instanceId` is stable for one process and `sequence` increases monotonically
within that process, so events from concurrent reviewer and review-handler
instances can be merged without parsing human console strings. Event data is
depth-, count-, and string-bounded, and sensitive key names are redacted.
Candidate, phase, blocked-delivery, completion, failure, and waiting events use
the same envelope in both agents while retaining agent-specific payloads.
Schema version 2 adds periodic `agent.heartbeat` events during long blocking
operations and an `agent.stopped` lifecycle event on orderly shutdown. These
events are diagnostic only and cannot change agent selection or delivery.

### Live operations dashboard

`Start-DevPilotDashboard.ps1` is a read-only, OpenCode-inspired terminal UI
over the reviewer and review-handler event streams. It observes existing agent
processes; it cannot start, stop, retry, promote, or otherwise control them.

For the simplest workflow, launch preview-only agents and watch them together
in the current terminal:

```powershell
# Both agents, one cycle each:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Both

# Both agents, continuous 15-minute cadence:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Both -Continuous

# One agent:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Reviewer -Continuous
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent ReviewHandler -Continuous
```

The shared launcher resolves the conventional
`.github\copilot\agents\reviewer.config.json` and
`.github\copilot\agents\review-handler.config.json` paths from the current
consumer repository. It starts each selected agent in a separate process with
`-OutputMode Json` and no mutating or notification switches. The agents share
one generated session root, so one dashboard can group their live and retained
instances.

Compatibility wrappers provide the shorter single-agent names:

```powershell
.\tools\Watch-DevPilotReviewer.ps1 -Continuous
.\tools\Watch-DevPilotReviewHandler.ps1 -Continuous
```

In the default one-cycle mode, closing the dashboard does not terminate an
agent that is still running. Reattach later with the state path printed by the
launcher:

```powershell
.\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir <printed-state-path>
```

For a short continuous test cadence:

```powershell
.\tools\Watch-DevPilotAgents.ps1 -Agent Both -Continuous -IntervalSeconds 60
```

Continuous agents remain preview-only. They scan until the dashboard exits,
then the launcher stops every process tree it owns so no hidden background
agent is left running. Fixed pull request IDs are intentionally incompatible
with `-Continuous` to prevent repeatedly processing one pull request. Use the
ordinary agent entry points, not the watch launchers, for code changes,
publishing, votes, requeues, auto-complete, or notifications.

Install and build its locked dependencies once:

```powershell
Set-Location .\src\DevPilot.Dashboard
$env:npm_config_cache = "$PWD/.npm-cache"
npm install
npm run build
npm test
npm run test:renderer
Set-Location ../..
```

Then point the dashboard at one or more agent state roots:

```powershell
.\tools\Start-DevPilotDashboard.ps1 `
    -StateDir "$env:LOCALAPPDATA/<state-namespace>"
```

The standalone observer searches below each root for both agents' per-instance streams,
including state layouts with agent-name subdirectories. It can also read an
explicit capture with `-EventLogPath`. The layout adapts from three panes on a
wide terminal to a single overview/detail route below 80 columns. Use arrows
or `j`/`k` to select, `Enter` for detail, `i` for the inspector, `e` for
events, `o` to open a validated PR link, `Ctrl+P` for the contextual command
palette, `?` for help, and `q` to quit.

The package keeps its OpenTUI, SolidJS, TypeScript, and Bun versions locked
under `src/DevPilot.Dashboard`. Bun is restored locally by `npm install`; no
global Bun installation is required. See
[`src/DevPilot.Dashboard/README.md`](src/DevPilot.Dashboard/README.md) for
architecture and troubleshooting.

`-PromotePreview` publishes the artifact's **delivery manifest** — the exact
comment and thread-reply lists, summary and vote that appeared in the Markdown you read — and
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

Teams notifications are also wrapper-owned. With
`teamsNotifications.directAuthor.enabled` and `-EnableTeamsNotifications`, a
posted review is sent directly to the reviewed PR's author using the UPN in
ADO's `createdBy` identity. The configured `recipientUpn` and
`-TeamsRecipientUpn` are fallback values only when ADO does not expose a usable
author UPN. Channel and direct delivery are deduplicated independently.

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
- **The summary describes the review, not the delivery.** Its bounded,
  structured sections record the applied review guidance, verified behavior,
  rollout and validation analysis, security assessment, and recommendation.
  A summary with no findings is created as a closed thread because it is
  informational and requires no action; a summary with findings remains active.
  The body also quotes how much of the review is *eligible* to post - never how
  much actually posted, and never a claim that anything was published. That is both honest
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
- **Configuration cannot silently do nothing.** A capability switch whose
  config is not populated is a startup error, and a config key the agent does
  not read is rejected rather than ignored. The failure this prevents is an
  operator who believes something is enabled while it delivers nothing —
  which is worse than the feature being absent, because absence is visible.
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
- **ADO candidate enumeration uses bounded offset pagination.** The reviewer
  fetches up to 20 pages of 100 active PRs and fails the cycle rather than
  silently truncate beyond 2,000. ADO does not expose a stable snapshot:
  concurrent PR creation/completion can move records between `top`/`skip`
  requests, so an unusually busy repository can still miss one during a cycle.
  A later cycle normally sees it. `-PullRequestId` bypasses pagination and
  reaches the requested PR directly.
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
