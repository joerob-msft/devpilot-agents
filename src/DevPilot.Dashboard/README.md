# DevPilot Operations Dashboard

Direct and attach-only launches remain visibly observe-only. A trusted
`Watch-DevPilot*.ps1` launcher may opt in automatic operations, a long-lived
broker descriptor, and one or both manual roles. The renderer cannot exceed
the launcher-derived capability ceiling.

A terminal operations console for observing DevPilot reviewer and
review-handler instances and, only under a trusted launcher, manually
starting either agent by PR ID through the restricted broker contract,
without requiring retained history.

The History view is an independent retained PR projection keyed by
provider-verified repository identity plus PR number. It merges Reviewer and
Review Handler outcomes without merging same-numbered PRs from different
repositories. History also lists automatically archived **exited instances**
with their raw events, source log path, and reported outcome (or explicit
unknown outcome). Legacy schema-v2 streams use these instance rows but never
enter canonical PR history.

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
shows **OPERATIONAL**, **PREVIEW**, or **OBSERVE**. Press `m` from Current,
Live, or History (or choose **Start Agent by PR ID** in `Ctrl+P`) to open the
same blank PR-entry form. Reviewer is the default; `Tab` selects Review
Handler. Uses the selected agent's configured repository.

Enter the complete ASCII decimal PR ID in `1..2147483647`, then press
`Enter` to resolve it and load the preview. Invalid input is not filtered into a different ID;
oversized/control-containing input requires `Ctrl+U` to clear. The read-only
`profile-current` broker RPC accepts only PR ID and role, derives the repository
from trusted launcher configuration, and creates no dispatch draft or snapshot.
No History entry is required or fabricated.

**m → ID → Enter (load and preview) → Enter (start)** is the complete default
flow. Resolution immediately fetches a fresh key-bound capability preview.
Verify the repository, PR title, and agent. The target and role are frozen;
cancel/reopen to change either. Press `Enter` after the preview is displayed
to **START**. Optional context is behind `p` in the preview (up to 512 Unicode
scalars); `Enter` returns to the preview without starting or creating another
draft. `Shift+Enter` inserts a newline; pasted multiline instructions remain data. Only the
separate post-preview confirmation starts
work. Operational launches retain their authorized comments/pushes; PreviewOnly
remains terminal no-write with widening locked. `Esc` cancels pending resolution
or describe; stale responses are ignored.

The panel clearly distinguishes **NOT STARTED / READY TO START**, **STARTING**,
and **STARTED / RUNNING**. Acceptance shows the child PID and elapsed time even
before the first event, with an explicit waiting message (not a claim that the
model is already working). Matching events show the current phase and latest
progress. Completion, failure, blocking, cancellation and lost monitoring are
distinct. Exit zero without a reported work outcome does not imply review success.
Progress is tied to the exact accepted dispatch, repository, role and PID, not
the selected row or an automatic watcher on the same PR.

Capability widening is separate: `w` opens the disclosure, `c` reviews the final
blast radius and `y` mints the grant. Enter never advances these challenges;
minting never starts work. The ordinary post-preview Enter confirmation is still
required afterward. No launcher or broker authority gate is changed.

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
| `m` | Start Agent by PR ID from any main view, when trusted policy is available |
| `Tab` in PR entry | Choose Reviewer or Review Handler (before resolution only) |
| `Enter` in PR entry | Validate ID, resolve the configured repository, and load a fresh keyed preview |
| `Ctrl+U` in PR entry | Clear input, including an oversized/rejected paste |
| `p` in preview | Edit optional instructions (not a mandatory step) |
| `Enter` in instructions | Return to preview; does not start work |
| `Shift+Enter` in instructions | Insert a newline |
| `Enter` in preview | Explicitly start the exact displayed broker snapshot |
| `c` | Cancel only the active broker-owned manual child |
| `i` | Open or close the inspector |
| `e` | Bounded raw-events overlay; Left/Right changes filter |
| `w` | Next failed, blocked, or diagnostic-bearing instance |
| `o` | Open the selected PR's validated HTTP(S) URL |
| `Ctrl+P` | Dashboard command palette, including Start Agent by PR ID |
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
completed. Overdue instances whose local PID is positively observed absent
are automatically removed from both Current and Live, including the newest
such row in a group. They remain available under **EXITED INSTANCES** in
History: select a row for its narrative/log path or press `e` for raw events.
This also retains legacy/unverified streams and PR-less startup failures
without inventing canonical PR records. A missing completion is labeled
**Interrupted / outcome unknown**, never successful.

The dashboard probes only explicitly local streams, at most every five seconds
and only after both events and heartbeats are overdue by 20 seconds. A current
trusted Watch launch identifies its actual child stdout captures through private
startup metadata; the broker checks the real Dashboard/launcher parent chain and
launcher start identity before forwarding that metadata on its existing channel.
Accepted manual children are bound to their exact event path, PID, role,
repository, PR and dispatch ID. No new CLI trust switch or process authority is
introduced. An existing local path, present PID, or event's claimed host is never
origin proof: arbitrary `--state-dir`/`--event-log`, copied, remote/container,
attach-only and older streams without current provenance remain stale warnings.
Golden/continuous Watch uses an opt-in live stdout tee on the existing typed
process helper, not `Start-Process` argument reconstruction. Its owner-private
capture exists before the broker starts and receives complete frames while the
child runs. It retains a 10 MiB active file plus one 10 MiB rotation, the existing
bounded diagnostic tail, and at most 256 Ki characters of an unfinished frame.
Rotation preserves whole frames; final draining does not rewrite a file already
being tailed. Capture I/O or oversized-frame failures are reported on stderr,
continue draining the child, and fail the launch after existing cleanup finishes.
Default non-live helper calls and manual prompt redaction remain unchanged.
Node's signal-0 existence check sends no signal. Only `ESRCH` confirms absence;
permission/unsupported errors and present (possibly reused) PIDs remain visible
as warnings. Observations do not establish process identity or control authority.
Concurrent events invalidate a pending observation; newer events restore an
archived row. Reloading logs can re-derive an archive only with fresh trusted
provenance; it never deletes state.
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
argv, environment, logs, events, or diagnostics. Confirmation shows
the source commit, allowed actions, mandatory denied actions, and dynamic
constraints. Policy digests and PR-state fingerprints remain bound and verified
by the protocol without dominating the operator view.
`source-changed`, `policy-changed`, `pr-state-changed`, `delivery-pending`,
`already-running`, broker/child failures, and cooperative/forced cancellation
are rendered with distinct safe detail.
For `already-running` / `state-contended`, another run of the selected role is
using this repository's durable state, possibly for a different PR. Wait for it
to finish, then retry. Removing a stale row does not release that lock; the
dashboard neither queues the request nor cancels automatic work.

## Architecture

- `domain.ts` validates and bounds both legacy instance-observation events and
  schema-v3 provider-verified repository identity.
- `history.ts` independently retains up to 5,000 canonical repository/PR keys,
  deterministic role outcomes, filtering, hide/restore, jump, and eviction.
- `tailer.ts` discovers streams and maintains one rotation-safe byte cursor per
  file. Accepted event paths are registered immediately while preserving the
  flat `logs\events\<role>` layout and `.jsonl.1` through `.jsonl.5` rotation.
  A dynamically accepted path may precede file creation: initial ENOENT is
  retried quietly for 30 seconds, then reported once as uncertain monitoring
  while polling continues. Explicit CLI missing files, access errors, and
  disappearance after observation still produce diagnostics.
  Complete malformed lines become bounded diagnostics; partial lines stay
  buffered until a newline arrives. Its post-ingestion poll hook reconciles
  process observations with the reducer.
- `process-observer.ts` checks local PID existence without delivering a signal.
  It cannot grant process-control or dispatch authority.
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
