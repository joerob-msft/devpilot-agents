# Repo-local fleets and swarms

The Fleet POC adds a **local website**, repo-owned agent definitions, interval
scheduling, and bounded worker-plus-synthesis swarms. It is separate from the
existing Reviewer / Review Handler broker: observing their event files does not
give Fleet control of their permissions, schedules, or process lifetimes.

## What is a fleet, and when is a swarm useful?

A **fleet** is a managed collection of agents with distinct responsibilities:
for example, a repository-efficiency reviewer and a toolkit-maintenance reviewer.
They share catalog, scheduling, capacity limits, state, and monitoring, but do
not need to collaborate on every run.

A **swarm** is a bounded collaboration on one objective. In this POC, independent
workers examine complementary evidence, then a synthesis agent combines their
accepted results into a prioritized proposal. The swarm finishes; it is not a
permanent conversation between unlimited agents.

Use a swarm when different perspectives or source slices materially improve a
decision, or when independent investigations can usefully run in parallel.
For example, repository-navigation and implementation reviewers can identify
different barriers to adding an agent, then produce a combined improvement plan.
Use one agent for a focused review, and a deterministic script for a mechanical
check. Multiple models add latency, usage, and opportunities for disagreement;
agreement between workers is not independent proof that a conclusion is correct.

## Start in this checkout

Prerequisites: Windows, Node 24 or newer, PowerShell 7, Git, and a current installed
`copilot.exe` supporting tool availability filtering and JSON output. Authenticate
the GitHub CLI (`gh`) with the account you intend workers to use, or supply
`COPILOT_GITHUB_TOKEN` in the launching environment. Workers do **not** inherit
the interactive session's extensions, MCP configuration, custom instructions,
or provider selection.

```powershell
npm ci --prefix .\src\DevPilot.Fleet
npm run build --prefix .\src\DevPilot.Fleet
node .\src\DevPilot.Fleet\dist\src\cli.js serve --repo .
```

Open the printed loopback address, normally `http://127.0.0.1:4317`.
Keep the terminal open. Ctrl+C stops admission, cancels admitted work, and drains
before releasing ownership. No background service or cloud resource is installed.

The checked-in `.devpilot` directory supplies two agents and an improvement-review
swarm. Its agents select navigation/CI documentation and Fleet implementation
files respectively. Newly initialized consumer repositories start smaller, with
only their selected README/input file. Preview the packet before selecting
**Run now** or **Run swarm**. These
actions consume model usage under the authenticated account.

## Add this toolkit to another repository

Use the toolkit checkout's absolute CLI path with the consumer root:

```powershell
node <toolkit>\src\DevPilot.Fleet\dist\src\cli.js init --repo <consumer-root>
node <toolkit>\src\DevPilot.Fleet\dist\src\cli.js serve --repo <consumer-root>
```

`init` uses `README.md` as the initial input. Pass `--input <relative-file>` to
select a different existing file. It refuses to overwrite an existing `.devpilot`
directory. The consumer owns this configuration and its prompts; the toolkit owns
the execution policy and website. Review and pin the toolkit version for shared use.

## Create an agent without changing toolkit code

This section adds a tool-disabled packet-analysis role, not a new harness-backed
agent loop. For the latter, see [Adding a full agent](adding-an-agent.md).

1. Add `.devpilot/prompts/my-agent.md` describing the desired analysis.
2. Add a manifest entry referencing it and an explicit input profile.
3. Select **Reload definitions**, **Preview**, and **Run now**.

Example entry in the `agents` array:

```json
{
  "id": "documentation-review",
  "prompt": ".devpilot/prompts/my-agent.md",
  "inputProfile": "repo-packet",
  "timeoutSeconds": 600,
  "schedule": { "enabled": false, "everyMinutes": 60 }
}
```

Input profiles are explicit file lists, not recursive globs:

```json
{
  "repo-packet": {
    "files": ["README.md", "src/DevPilot.Fleet/package.json"]
  }
}
```

Manifest path strings use `/` as their portable separator. Absolute paths, `..`,
alternate data streams, linked paths, secret-looking paths, unsupported
extensions, and credential-looking content are rejected. There are limits of
20 files per profile, 64 KiB per file, and 128 KiB total input content. These
checks are not a comprehensive secret scanner: review what you select.

**Execution is packet analysis, not live code exploration.** The host reads the
explicit inputs and sends their contents to the model. The model gets no tools:
no shell, file tools, MCP, delegation, or edits. It can only return a bounded
summary and proposals. Adding a role does not add tool permissions.

Accepted results must contain exactly `schemaVersion`, `nonce`, `inputHash`,
`summary`, and `findings`. The runner supplies the binding and field limits.
Results may be a complete JSON object or use the `FLEET_RESULT:` prefix;
conflicting or malformed results fail closed. A failed parser does not trigger
another model invocation. Bounded invalid answers are retained privately for diagnosis.

Rejected attempts have an **Inspect rejected answer** action. It loads at most
65,536 characters from that known attempt's private `answer.txt`, renders it as
untrusted plain text, and reports field-level errors such as
`findings[1].path_note: unexpected field`. It does not serve arbitrary paths,
edit the answer, change the saved outcome, or rerun work. Older rejected runs
can be inspected without rewriting their original generic error. If capture
reached its limit, the view explicitly warns that the answer may be incomplete.
Diagnostics explain a rejection; they never override the bridge's decision.

The CLI can mask credential-like examples in its stdout input echoes and break
their JSON quoting. Fleet leaves masking enabled. Each attempt selects an
explicit CLI session ID and audits that session's private journal (maximum
4 MiB) for completion, event identities, and tool activity. Only malformed
`user.message` / `system.message` stdout echo envelopes may be omitted, with a
persisted **Execution note**. Completed answer identities must match the journal,
and the final stdout result must match the session. Malformed answer/result/tool
records, unknown malformed records, and missing or invalid journals still fail
closed. Answers come only from redacted stdout, never unredacted journal text.
For transport failures or omitted echoes, bounded stdout is retained privately
as `stdout.jsonl`; it is not exposed by a generic file-serving endpoint.

## Schedules and swarms

Schedules are disabled at startup, including after restart. Enable one explicitly
in the website. Manifest `enabled` is a reserved default and must remain `false`;
the host's effective schedule state is separate from the reviewed definition.
Intervals are 1-1440 minutes. A due tick coalesces missed polls and does not
overlap already admitted work for that agent. Admission errors disable that
schedule and produce a visible diagnostic.

A swarm recipe names two or three unique workers and a synthesis prompt:

```json
{
  "id": "improvement-review",
  "workers": ["repo-efficiency", "toolkit-maintainer"],
  "synthesisPrompt": ".devpilot/prompts/synthesis.md"
}
```

There are at most two new-runner attempts executing simultaneously. Synthesis
counts toward that limit and the four-node maximum. It receives the accepted,
persisted worker artifacts, not a re-read or another model pass over their inputs.
A required worker failure blocks synthesis. Cancelling a swarm cancels pending
admission and requests termination of active workers.

This is not an arbitrary DAG engine. There are no recursive agents, dynamic
worker creation, automatic retry, issue creation, or auto-fix/merge actions.

## Website interpretation

- **Agents:** catalog, packet preview, schedule state, run-now controls.
- **Swarms:** explicit recipe and worker/synthesis relationships.
- **Runs:** attempt status, elapsed time, input hashes, source revision, findings,
  cancellation, and structured result artifacts.
- **Existing agents:** observation-only cards for explicitly attached event files.

```powershell
node .\src\DevPilot.Fleet\dist\src\cli.js serve --repo . `
  --observe <absolute-reviewer-events.jsonl> `
  --observe <absolute-handler-events.jsonl>
```

Attach up to eight known JSONL files. Observation is limited to their final
1 MiB and complete lines. File errors and incomplete coverage are explicit.
Their processes are **not** included in Fleet's two-slot limit; keep their
existing owners responsible for resource limits and control.

SSE updates show host-observed lifecycle state, not live model reasoning or
tool progress. Fine-grained progress and monetary cost are unknown. A current
heartbeat or an observed event is not proof of successful work.

Outputs retain input hashes, prompt hash, and Git HEAD at admission. The website
marks evidence stale if HEAD or selected input-file contents change, including
uncommitted edits. Missing current inputs are stale; unavailable Git state is
unknown. A worker's claims are model-reported evidence, not independently verified facts.

## Storage, restart, and limits

Default state is outside the repository:

```text
<home>\.devpilot\fleet\<repository-path-hash>\
  owner.json
  state.json
  runs\<attempt-id>\
    request.json
    bridge.json
    outcome.json
    result.json
    cli-home\
    workspace\
```

The harness establishes a private, owner-bound state directory. Each attempt
has a separate CLI home and workspace. Authentication is supplied in memory
using the explicit token or `gh auth token`; user settings/login caches are not
copied. Local executor session diagnostics can still contain selected input and
model output. Treat this directory as private data.

One supervisor owns the state lock. It persists admission before launching.
Results and state use atomic replacement. Observation logs never authorize work.
The POC stops admission at 200 retained attempts/requests; pending synthesis
slots are reserved. Archive the complete private state **offline, after all
owners and workers have stopped**, before beginning a new retention period.
No automatic artifact deletion or hidden history pruning occurs.

`--state <private-directory>` can select a storage location. Never run multiple
state roots for the same repository concurrently; the POC has no distributed
or cross-state-root ownership protocol.

Normal shutdown releases ownership. After a crash:

```powershell
node .\src\DevPilot.Fleet\dist\src\cli.js recover --repo .
```

Recovery refuses if a recorded owner/bridge PID remains present, even if PID
reuse is suspected. It also refuses `unknown` cleanup outcomes. Inspect the
recorded processes instead of force-clearing an active lock. A new server marks
unfinished work interrupted, leaves schedules disabled, and never auto-replays it.

Each attempt has a 10-600-second execution deadline. Cleanup can take additional
time. Output capture is capped at 1,048,576 characters **per stream**; overflow
terminates work and records failure. This is not a token/spend ceiling.
If bridge cleanup cannot be confirmed, status is `unknown`, further admission
stops, and ownership is retained for inspection.

## POC boundaries

The web server binds only to `127.0.0.1` and enforces Host/Origin checks and
per-session mutation tokens. Do not publish or reverse-proxy it. It is not
multi-user authentication and does not protect against a malicious process
already running as the same user.

Tool filtering and a private workspace are **not an OS sandbox**. The approved
CLI and local wrapper remain trusted code. Windows Job Objects provide
descendant cleanup; the current spawn/assignment boundary is not an atomic
sandbox launch. Linux execution deliberately remains blocked until equivalent
containment, identity, and state behavior are qualified.

This release does not connect telemetry, incident-management, or partner data,
does not deploy to a cloud host, and does not promise unattended credential
renewal. Those are follow-on adapters, not disguised demo integrations.

## Development

```powershell
npm test --prefix .\src\DevPilot.Fleet
Invoke-Pester -Path .\tests\FleetOutputLimit.Tests.ps1,.\tests\FleetProtocol.Tests.ps1,.\tests\FleetBridge.Tests.ps1,.\tests\FleetCliStream.Tests.ps1
```

Offline tests use an explicitly injected fixture executor, never a production
CLI switch or browser-accessible mock mode.

The opt-in live exercise creates a temporary example repository and executes a
real two-worker-plus-synthesis swarm using synthetic, nonsensitive input:

```powershell
$env:DEVPILOT_FLEET_LIVE = '1'
npm run test:live --prefix .\src\DevPilot.Fleet
```

It consumes model usage and retains the printed private artifact path for
inspection. It is not part of automatic CI and does not claim connection to
production data sources.
