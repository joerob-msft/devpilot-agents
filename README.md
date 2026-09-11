# DevPilot Agents

> Manual dispatch is available only when a trusted `Watch-DevPilot*.ps1`
> launcher explicitly supplies a broker descriptor. Direct and attach-only
> dashboard launches remain visibly observe-only.
> Only PowerShell launchers create the hidden broker descriptor. Manual policy
> is independent of watched roles, and Reviewer approval votes are always
> denied. Dispatch freezes a one-use configuration snapshot, binds separate
> policy and PR-state digests, and does not authorize model work until the child
> owns the canonical lease and durable lock, deletes the protected prompt,
> reports `ready`, and receives `proceed`.

A portable harness for **autonomous, wrapper-governed coding agents** driven by
GitHub Copilot CLI.

Agents run unattended on a developer machine, pick up work from a pull-request
host, reason about it, and make bounded changes. The design principle is that
the **model reasons; the wrapper decides**. A trusted PowerShell wrapper selects
and binds the work, owns all state, performs every external write, and validates
everything the model returns. The model never selects its own work and never
writes to the PR host directly.

> **Status: pilot.** Two agents (`reviewer` and `review-handler`) are
> implemented for Azure DevOps, with a shared read-only dashboard and trusted
> launchers for observing or operating either or both. Interfaces will change.

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
  DevPilot.OwnerPipeline/    # experimental generic Owner review facade
  DevPilot.OwnerAdapters/    # read-only production/replay acquisition boundary
  DevPilot.OwnerCapability/  # preview-only injected Owner semantic boundary
  DevPilot.OwnerModelRunner/ # fail-closed no-tools preflight, fake process, and replay runner
  DevPilot.OwnerOrchestrator/ # preview-only v2 cohort state lifecycle
  DevPilot.Dashboard/        # read-only reviewer/review-handler operations TUI
  OwnerObserver/             # read-only Owner implementation parity adapter
  Agents/
    review-handler/          # an agent: script + prompt + fixtures
    reviewer/                # an agent: script + prompt
samples/                     # example configs for real repositories
tools/                       # launchers, dashboard entry point, and repo checks
docs/                        # how to add an agent
```

The experimental Owner facade and its acquisition boundary are documented in
[docs/owner-pipeline-facade.md](docs/owner-pipeline-facade.md) and
[docs/owner-production-adapters.md](docs/owner-production-adapters.md). The
injected semantic execution layer is documented in
[docs/owner-semantic-capability.md](docs/owner-semantic-capability.md), and its
bounded process/replay adapter in
[docs/owner-model-runner.md](docs/owner-model-runner.md). The layer 5 preview
cohort orchestrator is documented in
[docs/owner-preview-orchestrator.md](docs/owner-preview-orchestrator.md).
These layers remain preview-only and separate from the deployed reviewer,
scheduler, state, and writer.

**Consumers keep only a config file.** Nothing employer-, repository-, or
person-specific lives in this repo outside `samples/` — a CI check enforces that
(`tools/Test-NoEmployerSpecifics.ps1`).

The independent [Owner observer](docs/owner-observer.md) reads sanitized local
v1 or future v2 artifacts into one normalized, zero-write parity contract.
The [Owner parity qualification layer](docs/owner-parity-qualification.md)
executes replay candidates in a separate state root, evaluates eight explicit
gates, compares canonical semantic bindings, proves exact critical v1 bytes
stayed unchanged while only declared append-only files grew, and emits only a
sanitized aggregate artifact for source control.

---

## Quick start

```powershell
# 1. Load the harness (from a checkout; a published module is planned)
Import-Module .\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1

# 2. Copy a sample config into the repository you want the agent to work on
#    e.g. <your-repo>\.github\copilot\agents\review-handler.config.json

# 3. Prove it works offline — no network, no Copilot process
.\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1 -DryRun `
    -ConfigFile <your-repo>\.github\copilot\agents\review-handler.config.json

# 4. First live cycle. Every mutating capability is OFF by default:
#    this analyses a PR and writes nothing.
.\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1 -Once `
    -ConfigFile <your-repo>\.github\copilot\agents\review-handler.config.json `
    -OperatorAlias <your-alias>

# Target one of your PRs explicitly:
.\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1 -Once `
    -ConfigFile <your-repo>\.github\copilot\agents\review-handler.config.json `
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
.\src\Agents\reviewer\Start-ReviewerAgent.ps1 -DryRun `
    -ConfigFile <your-repo>\.github\copilot\agents\reviewer.config.json

# 1. Preview one specific PR. Posts nothing; writes a .md to read and a .json beside it.
.\src\Agents\reviewer\Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>\.github\copilot\agents\reviewer.config.json `
    -OperatorAlias <your-alias> -PullRequestId 12345

# 2. Read the .md. If you agree, publish EXACTLY that review - no second model run.
.\src\Agents\reviewer\Start-ReviewerAgent.ps1 `
    -ConfigFile <your-repo>\.github\copilot\agents\reviewer.config.json `
    -OperatorAlias <your-alias> `
    -PromotePreview <state-dir>\previews\pr12345-<commit>-<stamp>.json `
    -EnableFindingComments -EnableThreadReplies -EnableSummaryComment

# Unattended alternative: review and post in one run. Faster, and nobody read it first.
.\src\Agents\reviewer\Start-ReviewerAgent.ps1 -Once `
    -ConfigFile <your-repo>\.github\copilot\agents\reviewer.config.json `
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
.\src\Agents\reviewer\Start-ReviewerAgent.ps1 -OutputMode Compact `
    -ConfigFile <path> -OperatorAlias <alias>

# Full operator diagnostics
.\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1 -OutputMode Detailed `
    -ConfigFile <path> -OperatorAlias <alias>

# Feed an external monitor
.\src\Agents\reviewer\Start-ReviewerAgent.ps1 -OutputMode Json `
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

`tools\Start-DevPilotDashboard.ps1` is an OpenCode-inspired terminal UI over
reviewer and review-handler event streams. Direct and attach-only launches are
observe-only. A trusted `Watch-DevPilot*.ps1` launcher can enable automatic and
manual Reviewer or Review Handler operations. The TUI can display, narrow, and
explicitly confirm only the launcher-derived capability ceiling; it cannot
exceed that ceiling.

The dashboard requires Node.js 24 or newer, PowerShell 7 for the watch
launchers, and an interactive terminal at least 60 columns wide. Restore and
build the locked dashboard dependencies once from the toolkit checkout:

```powershell
Set-Location .\src\DevPilot.Dashboard
$env:npm_config_cache = "$PWD\.npm-cache"
npm ci
npm test
npm run test:renderer
Set-Location ..\..
```

The launchers deliberately never install dependencies. If public npm is
blocked, configure npm to use your organization's approved registry mirror
before running `npm ci`.

For the primary operational workflow, run the launcher while the current
directory is the consumer repository whose conventional agent configs should
be used:

```powershell
# Both agents loop continuously. Reviewer posts review results; Review Handler
# replies, applies and validates fixes, resumes work, and pushes updates.
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Golden

# Same live workflow with a terminal no-write capability ceiling:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Golden -PreviewOnly
```

`-Golden` is intentionally explicit because it grants write authority. It
enables Reviewer finding comments, thread replies, and summaries, plus Review
Handler replies, buddy requeues, code changes, local validation, session
resume, and push. It does **not** enable Teams notifications, shared PR-reference
writes, Reviewer approval votes, or Review Handler auto-complete. Those remain
behind their separate gates.

`-PreviewOnly` is not an omission-based convention. It is a terminal,
non-delegable ceiling that disables automatic and manual PR mutations,
notification delivery, Settings widening, and delegated grants. Use `-DryRun`
only for an agent's offline self-check; it is not the live PreviewOnly mode.

Every launch starts in **Simple** mode: a boxed left agent sidebar with selected
activity beside it on wider terminals, or a compact list on narrow terminals.
Use `Enter` for details and **`m` Start agent, `h` History, `a` Advanced, `q` Quit**.
Advanced keeps the full panes, filters, diagnostics, settings, and stale-instance
controls; press `a` again to return to Simple. Changing the view never changes
the launch's authority.

Golden still starts **both agents automatically**, without a manual command,
and waits **900 seconds (15 minutes)** between successful scans by default.
Failures use the existing retry backoff. The compact automatic-polling status
shows the configured cadence and whether agents are scanning, waiting, or
paused for manual work. Press **`r` Scan now** in a main view to wake this
launcher's idle pollers early. It does not interrupt running work, queue an
extra scan behind a busy agent, or bypass manual-work priority. It also does
not restart stopped agents or grant control to an observe-only dashboard.
The configured interval and Operational/PreviewOnly permissions stay unchanged.

The golden TUI shows **OPERATIONAL** or **PREVIEW** in its header. Press `m`
from Current, Live, or History to **Start Agent by PR ID**, or select that
command in `Ctrl+P`. Enter a PR ID and use `Tab` to choose Reviewer (default)
or Review Handler, then `Enter` to resolve it in that agent's configured
repository and load the preview. No retained PR or History filter is required.
Press `Enter` again after the preview is displayed to start:
**m → ID → Enter (preview) → Enter (start)**. Optional instructions are behind
`p` in the preview, not a mandatory step. The panel shows **NOT STARTED** before confirmation, **STARTING** while
launching, and **STARTED / RUNNING** with the child PID and progress afterward.
The current launch and up to 20 recent,
independently trusted watch runs contribute to History. Every manual launch
revalidates the PR's current state, author/ownership eligibility, and work
lease before starting.
Manual Reviewer launches allow your own PRs; automatic scans still exclude them
by default. This does not grant approval-vote permission or bypass work leases.

If the same launcher already has conflicting work, the manual panel offers
**Replace and run now**, **Run next**, or **Back** in both view modes. Replace
is selected initially but does nothing until you explicitly confirm it.
It stops only that launcher's conflicting work and waits for confirmed process
tree exit and lock release. Run next lets the current PR finish before the
manual turn. Automatic scanning then resumes with its original settings.
Already-posted comments and pushes are not undone. Queues belong to this Watch
session; `c` cancels a pending request and quitting cancels the queue.
Changed PR data or permissions require a fresh preview and confirmation.
Work from another launcher, or work whose ownership cannot be established,
cannot be replaced through this prompt.

Advanced and compatibility modes remain available:

```powershell
# Existing bare behavior remains one preview cycle:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Both

# One operational golden cycle:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Golden -Once

# Operational Teams delivery remains independently opt-in:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Both -Operational `
    -EnableReviewerTeamsNotifications

# Explicit single-role and fixed-PR modes:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Reviewer -Continuous
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent ReviewHandler -Operational `
    -EnableReviewHandlerCodeUpdates
# One agent, or one specific PR:
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Agent Reviewer `
    -ReviewerPullRequestId 12345
```

The shared launcher resolves the conventional
`.github\copilot\agents\reviewer.config.json` and
`.github\copilot\agents\review-handler.config.json` paths from the current
consumer repository. Only the selected agents' configs are required. Override
them with `-ReviewerConfigFile` or `-ReviewHandlerConfigFile` when necessary.
The launcher starts each selected agent in a separate process with
`-OutputMode Json`. Without `-Operational`, it passes no mutating or
notification switches. Operational reviewer runs enable finding comments,
thread replies, and summaries. Operational review-handler runs enable thread
replies and buddy requeues. Code changes, pushes, votes, auto-complete, and
local validation remain disabled by default. Add
`-EnableReviewHandlerCodeUpdates` to let the review-handler find and resume the
originating Copilot coding session when available, make code changes, run local
validation, and push to the PR source branch. A missing local session starts a
fresh coding session; this option does not require local ownership. Reviewer
votes and review-handler auto-complete remain default-denied and require the
existing explicit, policy-authorized manual widening flow. Teams delivery is
separate and requires the
appropriate `-EnableReviewerTeamsNotifications` or
`-EnableReviewHandlerTeamsNotifications` switch. Shared thread registration also
requires `-EnableReviewHandlerTeamsPrReferenceWrites` and the configured
PR-reference mode described below. Unless `-StateDir` is
supplied, the agents share a generated session root. Golden mode also reads a
bounded set of trusted prior watch roots so one dashboard can group current
activity and cross-launch PR history.

Compatibility wrappers provide the shorter single-agent names:

```powershell
.\tools\Watch-DevPilotReviewer.ps1 -Continuous
.\tools\Watch-DevPilotReviewHandler.ps1 -Continuous
```

In a preview one-cycle run, closing the dashboard does not terminate an agent
that is still running. Reattach later with the state path printed by the
launcher:

```powershell
.\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir <printed-state-path>
```

For a short continuous test cadence:

```powershell
.\tools\Watch-DevPilotAgents.ps1 -Agent Both -Continuous -IntervalSeconds 60
```

Continuous agents scan until the dashboard exits, then the launcher stops every
process tree it owns so no hidden background agent is left running. Operational
agents are also always stopped when the dashboard exits, including one-cycle
runs. Shutdown is immediate and can interrupt an in-flight wrapper operation;
quit while agents are waiting between cycles when possible. Fixed pull request
IDs are intentionally incompatible with `-Continuous` to prevent repeatedly
processing one pull request.

To observe agents started separately, point the standalone dashboard at one or
more state roots:

```powershell
.\tools\Start-DevPilotDashboard.ps1 `
    -StateDir "$env:LOCALAPPDATA\<state-namespace>"
```

The standalone observer searches below each root for both agents' per-instance
streams, including state layouts with agent-name subdirectories. It can also
read explicit captures with `-EventLogPath`. The default **Live** list shows
instances with a heartbeat in the last 20 seconds, including waiting, failed,
and blocked agents that are still heartbeating. Stale rows stay off this list.
In Advanced, `l` toggles **Live** and the broader **Current session** view,
which also includes retained outcomes and unconfirmed stale instances.
Current trusted Watch children and accepted manual
children have explicit local-process provenance. When their overdue PID is
confirmed absent by a signal-free existence check, they leave Current and Live
automatically. Arbitrary, copied, remote/container, attached, and older streams
without that provenance remain stale warnings; local paths or matching PIDs do
not establish origin. Heartbeat gaps, access errors, and present (possibly reused)
PIDs never prove exit.
Golden's private stdout captures stream live through the existing typed process
helper, with 10 MiB active plus one 10 MiB rotation. Final draining never rewrites
a live capture. Capture failures are visible and do not interrupt child cleanup.
**History** retains PR outcomes plus exited-instance diagnostics, including
legacy streams and runs without a completion event; those say **outcome unknown**,
not success. In Advanced, `Delete` persistently dismisses a selected inactive
instance across dashboard launches; `Shift+Delete` restores dismissed instances.
A new heartbeat makes an instance visible again. Dismissal never stops a
process or deletes logs, locks, or agent state. The separate `x` command hides
a selected PR History row and `Shift+x` restores those rows only in the current
dashboard process.
From any main view, `m` opens the same blank **Start Agent by PR ID** form
when the trusted launcher enabled it. The full ID must contain only ASCII
digits and be in `1..2147483647`; invalid or oversized input never becomes a
different PR ID. `Ctrl+U` clears the field. The broker resolves only the chosen
role's trusted configured repository, which may differ between agents.
The first `Enter` resolves the target and automatically fetches a fresh,
key-bound preview. Verify the displayed repository, PR title, and role.
The target and role are locked for that attempt; cancel and reopen to change them.
Press `p` in the preview to edit optional instructions (512 Unicode scalars);
`Shift+Enter` inserts a newline and `Enter` returns to preview without starting.
The provider-backed preview shows the repository, PR, role, source commit,
allowed actions, and denied actions. A separate `Enter` **after the preview is
displayed** starts the exact bound snapshot, with the displayed operational capabilities
(including authorized comments and pushes), or with terminal no-write denies
under PreviewOnly. `Esc` also cancels pending resolution or describe reads;
late responses cannot revive a cancelled attempt.
The manual panel stays on that exact dispatch, independent of view filters or
automatic agents watching the same PR. It shows elapsed time and latest progress,
explicitly says when no events have arrived, and distinguishes finished, failed,
blocked, cancelled, and unknown monitoring status. Exit code zero without a work
outcome is reported as a child exit, not a successful review. `c` cancels the run.
Capability widening still requires its separate `c` / `y` challenge confirmations;
neither Enter nor instruction text can mint a grant.
`c` cancels the pending manual request or the accepted manual child, not an
unrelated observed agent. `q` awaits broker shutdown; Golden stops its own
automatic and manual process trees, never another launcher's workers.

Describe and dispatch failures remain distinct in the UI, including
`source-changed`, `policy-changed`, `pr-state-changed`, `delivery-pending`,
`already-running` with lease/state contention detail, broker launch failure,
child failure, and cooperative versus forced cancellation.

Simple shows its boxed sidebar at 100 columns and wider when at least four
content rows are available; otherwise it uses a single-pane list and detail
drill-down. **Advanced** adapts from three
panes on a wide terminal to a single overview/detail route below 80 columns
and exposes these additional controls alongside the common commands:

| Key | Action |
|---|---|
| Left / Right | Focus a visible pane |
| Up / Down / `j` / `k` | Select an instance |
| `Enter` / `Esc` | Drill into or back out of detail and timeline views |
| `Tab` / `Shift+Tab` | Cycle all, reviewer, and review-handler roles |
| `f` / `Shift+f` | Cycle Live, Current session, and History |
| `l` | Toggle Live-only and Current session |
| `Delete` / `Shift+Delete` | Dismiss an inactive instance across launches / restore dismissed instances |
| `m` | Start Agent by PR ID, without selecting a History row |
| `Tab`, then `Enter` in PR entry | Choose agent, then resolve the configured repository/PR and load preview |
| `p` in preview | Edit optional instructions; Enter returns to preview without starting |
| `Enter` in preview | Explicitly start after the preview has been displayed |
| `Shift+Enter` in instructions | Insert a newline |
| `x` / `Shift+x` | Forget selected/all history from dashboard view state |
| `i` / `e` | Toggle the inspector or bounded raw-events overlay |
| `w` | Select the next failed, blocked, or diagnostic-bearing instance |
| `o` | Open the selected PR's validated HTTP(S) URL |
| `Ctrl+P` / `?` | Open the command palette or help |
| `q` | Quit |

The package keeps its OpenTUI, SolidJS, TypeScript, and Bun versions locked
under `src\DevPilot.Dashboard`. Bun is restored locally by `npm ci`; no global
Bun installation is required. See
[`src/DevPilot.Dashboard/README.md`](src/DevPilot.Dashboard/README.md) for
architecture, controls, filtering semantics, and direct-debugging commands.

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
Reviewer channel notifications also tag that PR owner using the Entra identity
bound to the fresh ADO author record. If ADO does not expose a valid mention
identity, the original unmentioned notification is still sent rather than
losing the review signal.

**Local Teams channel threads (default):** the optional
`teamsNotifications.channel.threadReuseEnabled` setting defaults to `true`.
The first eligible notification creates a root; later notifications reuse the
protected local receipt for that repository, PR, and destination. Both roles on
one installation share it through `-DurableStateRoot`. Explicit `false` sends
independent channel messages instead.

**Shared PR references (Azure DevOps, opt-in):** set
`teamsNotifications.channel.prReferenceEnabled=true` in both role configs, with
threading enabled and identical `teamId`/`channelId`. This additional setting
defaults to `false`; enabling it switches routing from local-only roots to the
PR author's shared reference. Different operators keep **separate protected
state directories**, not a shared writable filesystem.

The author's Review Handler creates or registers the root and publishes its
reference in one **closed PR coordination thread**: a pending claim followed
by the ready Teams link. It does this before requiring actionable feedback.
Registration needs the additional wrapper-owned write permission:

```powershell
<toolkit-root>\tools\Watch-DevPilotAgents.ps1 -Golden `
    -EnableReviewerTeamsNotifications -EnableReviewHandlerTeamsNotifications `
    -EnableReviewHandlerTeamsPrReferenceWrites
```

Direct Review Handler invocations use `-EnableTeamsPrReferenceWrites` alongside
`-EnableTeamsNotifications`. This permission does not grant new model tools.
The wrapper checks the authenticated identity against the current PR author;
an operator alias or a comment's display name is not ownership evidence.
Other operators read the author-published, scope-bound reference and fetch the
**known Teams root directly**. No channel-history scan, continuation token, or
body-content filter is required. Coordination comments are routing metadata,
not review feedback, model instructions, or inbound Teams steering.

Both modes still require channel enablement, event subscriptions, and the
notification capability switch. `PreviewOnly` cannot register, publish, drain,
or enqueue messages for a later operational run. Direct chats remain independent.

Thread IDs and per-role/event/commit receipts live in a versioned local
subtree of the durable state root, outside per-Watch runtime state. Existing
notification records are not backfilled. State is bound to the current
destination, verified repository identity, and PR, and an exclusive file
lock coordinates local processes. A shared PR reference coordinates routing,
not cross-user event deduplication: another operator's review remains its own
notification. Historical conversations are not moved or deleted.

In shared mode, an offline author handler or unavailable reference does not
make reviewers create competing roots. Definitely-unsent notifications enter a
bounded protected local outbox. Each role drains it on later operational cycles,
even when no new review work is selected. Current subscriptions and PR/commit
state are checked again; stale notifications are not replayed as current advice.
An ambiguous POST is quarantined, not treated as retryable queued work.

**Concurrency limit:** run one author-handler bootstrapper for a PR. A PR comment
is **not an atomic distributed lock**, including when two machines use the same
author identity. Pending claims precede root creation, but conflicting or
uncertain claims fail closed rather than authorizing takeover. A confirmed local
root can be reconciled with its PR reference; a lost Teams POST acknowledgement
cannot safely be recovered by blindly creating another root. Strict global
exactly-once creation is not claimed.

The `notification.delivery` audit event reports delivery outcomes without changing
the PR work result. Local-only threading retains its audited independent fallback
after a definite stale-root rejection. Shared-reference mode does **not** create
an independent fallback root when the registered root or reference is unavailable.
Invalid state, contention, or an ambiguous send must not create another root:
an unconfirmed outcome stays unconfirmed rather than being blindly retried.
Do not delete pending PR references, thread state, outbox records, or lock files
to force a retry after a timeout;
first inspect the destination for the possibly delivered message.
Explicit Graph throttles are retried only when the transport exposes a valid
`Retry-After`, up to three attempts within the notification deadline; a
required delay is never shortened to fit that budget.

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
- **`-DryRun` self-checks are mandatory** and run offline. Offline DryRun
  validates repository address syntax but reports an unverified,
  non-dispatchable repository identity and does not create agent state.
- **Repository identity is provider verified.** Azure DevOps repository GUIDs
  must match provider metadata; GitHub repository IDs are retained as opaque
  decimal strings without JavaScript-number conversion, including IDs above
  53 bits. Event schema v3 carries this identity on every event and heartbeat.
- **Canonical work leases and durable state are shared across launchers.**
  The child acquires a lease keyed by verified repository identity, PR, and
  role, followed by a repository/role durable-state lock. Acquisition is
  bounded; contention reports `lease-contended` or `state-contended` and the
  continuous watcher proceeds to its next candidate/pass.
- **Runtime and durable state are separate.** `-StateDir` contains only
  per-instance runtime data. Reviewed/handled records use state schema v2 under
  `%LOCALAPPDATA%\DevPilot\state\v2` on Windows or the XDG user-state directory
  on Unix. Tests and controlled deployments can pass absolute, non-overlapping
  `-DurableStateRoot` and `-LeaseRoot` paths outside the repository.
- **Legacy state migration is explicit.** Before a live role first uses state
  v2, run `tools\Initialize-DevPilotDurableState.ps1` for one declared legacy
  role directory. The tool verifies repository identity and each PR/commit
  against the provider, refuses missing sealed delivery manifests or existing
  conflicting state, and records an idempotent migration receipt.
- **Forced analysis does not weaken writes.** The internal `-ForceAnalysis`
  path bypasses only the already-reviewed/already-handled analysis check.
  Existing records and fingerprints remain intact. A pending Reviewer delivery
  returns `delivery-pending` before model analysis and must be resolved through
  the existing sealed-delivery promotion flow.

---

## Extending

Adding an agent means adding a folder under `src/Agents/`, containing a wrapper
script, a cycle prompt, and any fixtures. The harness supplies everything else.

See [`docs/adding-an-agent.md`](docs/adding-an-agent.md).

---

## Known limitations

- **Agent execution is Azure DevOps only, today.** Canonical repository identity
  resolution supports Azure DevOps and GitHub, but GitHub agent execution still
  lacks complete thread, write, and validation adapters.
- **The local-validation tool ceiling is code-defined.** .NET and MSBuild repos
  work out of the box; adding another build ecosystem (npm, cargo, gradle)
  requires a toolkit change and a security review — deliberately, since the
  ceiling is a security boundary.
- **Telemetry is local JSONL.** Event schema v3 is the canonical history input;
  legacy v2 streams remain visible by instance but are not projected into
  repository/PR history and are never dispatch authority.
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

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `.\tools\Test-NoEmployerSpecifics.ps1`
and the agent `-DryRun` suite before opening a pull request.

## License

[MIT](LICENSE)
