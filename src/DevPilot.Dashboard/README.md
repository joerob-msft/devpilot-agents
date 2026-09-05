# DevPilot Operations Dashboard

Direct and attach-only launches remain visibly observe-only. A trusted
`Watch-DevPilot*.ps1` launcher may opt in automatic operations, a long-lived
broker descriptor, and one or both manual roles. The renderer cannot exceed
the launcher-derived capability ceiling.

A terminal operations console for observing DevPilot reviewer and
review-handler instances and, only under a trusted launcher, manually
dispatching a retained PR through the restricted broker contract.

The History view is an independent retained PR projection keyed by
provider-verified repository identity plus PR number. It merges Reviewer and
Review Handler outcomes without merging same-numbered PRs from different
repositories. Legacy schema-v2 streams remain visible in instance views but do
not enter canonical PR history.

## Golden path

Run the toolkit watcher from a consumer repository containing the conventional
Reviewer and Review Handler configs:

```powershell
& '<toolkit-root>\tools\Watch-DevPilotAgents.ps1' -Golden
```

This explicit authority-bearing mode starts both agents continuously.
Reviewer may post findings, replies, and summaries. Review Handler may reply,
requeue, apply fixes, run local validation, resume the originating coding
session, and push updates. Teams notifications, approval votes, and
auto-complete are not granted by Golden.

For the same live experience with no PR mutations:

```powershell
& '<toolkit-root>\tools\Watch-DevPilotAgents.ps1' -Golden -PreviewOnly
```

PreviewOnly is a terminal ceiling: automatic and manual writes, notifications,
Settings widening, and delegated grants are unavailable. The header always
shows **OPERATIONAL**, **PREVIEW**, or **OBSERVE**. Press `f` to reach History,
select a PR, press `m`, and use `Tab` to choose the manual role.

Golden History includes the current launch and up to 20 recent watch runs that
still satisfy the owner-private trusted-path contract. Unsafe prior roots are
reported and excluded; durable and lease roots are never scanned.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- Node.js 24 or newer and npm for the reproducible install and build
- No global Bun installation. `npm install` restores the locked Bun 1.3.14
  runtime used by OpenTUI.
- An interactive terminal at least 60 columns wide

Install and build explicitly from this directory:

```powershell
$env:npm_config_cache = "$PWD\.npm-cache"
npm install
npm run build
npm test
npm run test:renderer
npm run test:pty
```

`test:pty` is a Windows-only live integration test. It starts the built
dashboard with the locked Bun runtime in a real ConPTY, drives terminal input
and resize events, and requires a clean quit. Observe-only process behavior is
covered there; trusted dispatch and mandatory Reviewer vote denial remain
covered by the native renderer and broker protocol tests.

The repository launcher intentionally does not install dependencies:

```powershell
.\tools\Start-DevPilotDashboard.ps1 -StateDir C:\DevPilot\state
.\tools\Start-DevPilotDashboard.ps1 `
  -StateDir C:\ReviewerState,C:\HandlerState `
  -EventLogPath C:\captures\reviewer.jsonl
```

For direct debugging:

```powershell
npm start -- --launch-mode observe --state-dir C:\DevPilot\state --event-log C:\captures\events.jsonl
```

Each state directory is recursively scanned (to a bounded depth) for:

```text
logs\events\reviewer\*.jsonl
logs\events\review-handler\*.jsonl
```

Directories and files may appear after startup. Explicit event files are also
polled until they appear.

## Navigation

| Key | Action |
| --- | --- |
| Left / Right | Focus a visible pane |
| Up / Down / `j` / `k` | Select instance while the rail is focused |
| `Enter` | Drill from rail to narrative to current-run timeline |
| `Esc` / `b` | Dismiss overlay or move back toward the instance rail |
| `Tab` / `Shift+Tab` | Cycle all, reviewer, and review-handler roles |
| `f` / `Shift+f` | Cycle Live, Current session, and History views |
| `x` / `Shift+x` | Hide the selected retained PR history row / restore all hidden PR history rows for this dashboard process |
| `/` | Filter PR history by number, title, author, repository, or outcome |
| Number then `Enter` | Jump to and restore a unique retained PR number |
| `m` | Open manual dispatch for the selected retained PR when trusted policy is available |
| `Tab` in prompt | Select the manual Reviewer or Review Handler role |
| `Enter` in prompt | Insert a newline (never confirms execution) |
| `Ctrl+d`, then `d`, then `y` | Describe, review the first gate, and explicitly confirm the exact broker snapshot |
| `c` | Cancel only the active broker-owned manual child |
| `i` | Open or close the inspector |
| `e` | Bounded raw-events overlay; Left/Right changes filter |
| `w` | Next failed, blocked, or diagnostic-bearing instance |
| `o` | Open the selected PR's validated HTTP(S) URL |
| `Ctrl+P` | Contextual read-only command palette |
| `?` | Help |
| `q` | Quit |

Unavailable actions produce a brief status message instead of silently doing
nothing. The focused pane is visible in both the header and pane border.

The default **Current session** view contains every live instance plus only the
newest retained instance in each agent/session namespace group. This keeps old
runs out of the default view without hiding the most relevant recent outcome.
**Live** contains nonterminal derived statuses while lifecycle remains active,
including active failed, blocked, waiting, or stale agents. A completion event
followed by `agent.waiting` therefore remains Live. **History** contains
terminal retained runs whose lifecycle stopped or whose derived status is
completed.
Instances are grouped by agent and a deterministic session namespace: for
normal state roots, the namespace is the directory immediately above
`logs\events`; shared launcher role containers such as `reviewer` and
`review-handler` use their parent watch directory; for explicit event files,
it is the containing directory.
History rows include their completion timestamp and reported outcome.

Hide and restore affect only in-memory dashboard view state. They never change an agent
process, edits agent state, or deletes/truncates event logs. Numeric jump in the
history projection restores a hidden unique PR; same-numbered PRs across
repositories require repository selection.

The optional operator context is LF-normalized, rejects terminal control
characters, and is capped at 512 Unicode scalar values (including non-BMP
characters). It is sent only as bounded protocol data and is never placed in
argv, environment, logs, events, or diagnostics. Confirmation separately shows
the source commit, capability-policy digest, PR-state fingerprint, enabled
capabilities, mandatory disabled high-impact actions, and dynamic constraints.
`source-changed`, `policy-changed`, `pr-state-changed`, `delivery-pending`,
`already-running`, broker/child failures, and cooperative/forced cancellation
are rendered with distinct safe detail.

## Architecture

- `domain.ts` validates and bounds both legacy instance-observation events and
  schema-v3 provider-verified repository identity.
- `history.ts` independently retains up to 5,000 canonical repository/PR keys,
  deterministic role outcomes, filtering, hide/restore, jump, and eviction.
- `tailer.ts` discovers streams and maintains one rotation-safe byte cursor per
  file. Accepted event paths are registered immediately while preserving the
  flat `logs\events\<role>` layout and `.jsonl.1` through `.jsonl.5` rotation.
  Complete malformed lines become bounded diagnostics; partial lines stay
  buffered until a newline arrives.
- `dispatch.ts` starts only the absolute trusted PowerShell executable and
  fixed broker argv with `shell: false`, enforces 65,536-byte JSONL frames,
  correlates requests, and owns bounded cancel/shutdown behavior. It never
  derives capability policy.
- `reducer.ts` deduplicates by instance sequence, surfaces gaps, derives
  lifecycle and attention state, preserves bounded review completion details,
  retains at most 500 non-heartbeat timeline events per instance, and owns the
  bounded process-local history visibility state.
- `layout.ts` is a pure responsive decision function used by the SolidJS UI.
- `app.tsx` renders focus-aware OpenTUI panes and overlays. At 120 columns it
  shows three panes, at 80-119 it overlays the inspector, and below 80 it uses
  one pane. The primary hierarchy is current phase, elapsed/model activity,
  candidate story, completion summary, and the current-run narrative.

The UI displays only bounded summaries. Unknown envelope or `data` fields are
accepted but are not rendered as unbounded raw content. Browser opening is
fail-closed: only credential-free `http:` and `https:` URLs are passed as a
process argument to a platform opener, never interpolated into a shell command.
