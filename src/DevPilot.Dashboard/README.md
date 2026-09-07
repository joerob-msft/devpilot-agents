# DevPilot Operations Dashboard

Direct and attach-only launches remain visibly observe-only. A trusted
`Watch-DevPilot*.ps1` launcher may opt in automatic operations, a long-lived
broker descriptor, and one or both manual roles. The renderer cannot exceed
the launcher-derived capability ceiling.

A terminal operations console for observing DevPilot reviewer and
review-handler instances and, only under a trusted launcher, manually
starting either agent by PR ID through the restricted broker contract,
without requiring retained history.

Every launch starts in **Simple**. At 100 columns and wider, a clearly boxed
left sidebar lists agents, PRs, and statuses, with the selected item's latest
activity beside it. The sidebar is bounded to 40-42 columns; it is not the
Advanced inspector or filter layout. `Enter` opens pinned details in the main
pane; `Esc` returns to selection. Narrow terminals use the compact list and
full-width Enter/Esc drill-down instead. `h` switches Live/History and `a`
opens **Advanced**.
The main footer is `m Start agent | h History | a Advanced | q Quit`
(`h Live` in History), plus `r Scan now` when current-launcher automatic control
is available, with contextual detail/back controls. Authority and
actionable failures remain visible; Simple does not turn an operational
launch into preview-only mode.

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

Manual Reviewer launches include the operator's own PRs. Automatic scans still
exclude them unless explicitly configured otherwise. Selecting your own PR does
not grant approval-vote permission or bypass work leases.

The panel clearly distinguishes **NOT STARTED / READY TO START**, **STARTING**,
and **STARTED** (Advanced: **STARTED / RUNNING**). Acceptance shows elapsed time even
before the first event, with an explicit waiting message (not a claim that the
model is already working). Matching events show the current phase and latest
progress. Completion, failure, blocking, cancellation and lost monitoring are
distinct. Exit zero without a reported work outcome does not imply review success.
Progress is tied to the exact accepted dispatch, repository, role and PID, not
the selected row or an automatic watcher on the same PR. Raw PID and instance
identifiers appear only in Advanced.

Capability widening is separate and **Advanced-only**: `w` opens the disclosure, `c` reviews the final
blast radius and `y` mints the grant. Enter never advances these challenges;
minting never starts work. The ordinary post-preview Enter confirmation is still
required afterward. No launcher or broker authority gate is changed.

Golden History includes the current launch and up to 20 recent watch runs that
still satisfy the owner-private trusted-path contract. Unsafe prior roots are
reported and excluded; durable and lease roots are never scanned.

### Automatic polling and Scan now

Golden still starts **both automatic agents immediately** and uses the existing
900-second (15-minute) wait between **successful** scans. Failure backoff can
differ. The dashboard does not change these settings, infer deadlines, or show
a fabricated next-scan countdown.

The compact `Auto:` line in Simple and Advanced reports the broker's negotiated
roles, configured intervals (or once-only mode), and current worker states.
Mixed states remain role-specific. Missing or unsupported control is labeled
unavailable, not falsely reported as automatic polling being off. Event PIDs
and the operational/preview label do not grant this control.

Press **`r` / Scan now** in a main view, or select it in either command palette,
to wake eligible idle automatic workers from this same launcher. No additional
confirmation is needed: this does not change their existing authorization.
It never interrupts a model, supersedes manual priority, queues an extra scan
behind busy work, or restarts stopped/failed workers. The shortcut stays visible
while workers are busy; results distinguish each role's **wake requested**,
**already working**, **manual priority**, or **unavailable** outcome.
A wake acknowledgment is not proof that a model started. PreviewOnly remains
no-write, and no widening is performed.

`r` remains ordinary data in manual inputs and history filters. In Settings it
keeps its existing profile-refresh meaning; help and other overlays do not wake
workers.

Status is read on dashboard mount, then polled sequentially about every five
seconds while available. Scan completion requests a fresh status read; older
responses cannot overwrite it. A status-read error is visible and disables
Scan now until a healthy read succeeds, with at most three five-second retries.
Unsupported control, exhausted retries, shutdown, or fatal broker failure stops
polling. Scan errors are reported without automatically retrying the wake.
Polling never changes selection, inputs, or manual confirmation state.

### When another run is busy

In both Simple and Advanced, a scheduling-enabled current Watch launch can
offer **Replace / run now**, **Run next**, and **Back** after a typed busy
rejection. Replace is preselected, but preparing the proposal is read-only:
no work is cancelled until a separate `Enter` confirms the displayed proposal.
`Tab` or Up/Down changes the choice; changing the action obtains a fresh binding.
PageUp/PageDown scrolls the full scope, permissions, and constraints, even in a
short terminal. `Esc` or Back abandons an unconfirmed proposal safely.

The proposal identifies the current owned role and PR. Replace requests
cancellation of that exact current-launcher work before giving the manual PR a
turn; Run next waits for the **current PR**, not the entire automatic scan cycle.
Completed comments and pushes are not undone. Automatic work resumes after
manual completion; queued intents end with the Watch session.

Queued work is labeled **QUEUED**, **STOPPING CURRENT WORK**, **WAITING FOR
AUTHORITY**, or **REVALIDATING**, never started merely because it was queued.
`c` or `Esc` cancels only the queued intent. Its acknowledgment is shown as
**CANCELLATION ACKNOWLEDGED / CLEANUP PENDING**, not completed cancellation:
the panel stays open until a matching `resumed` update confirms scheduling-slot
release and restored automatic admission.
Cancellation or expiry of a queued request does not release an earlier manual
run's reservation. The panel waits while that run finishes and while automatic
startup is being confirmed; process creation alone is not a resumption signal.
If manual acceptance wins that race, the panel tracks that exact child instead;
`c` then cancels that manual run. Unconfirmed cancellation, lost confirmation,
or termination uncertainty never permits dismissal into a second dispatch.
`q` retains the normal broker-owned shutdown route.
If the broker reports both successful queued cancellation and acceptance for
the same request, the panel instead flags inconsistent state and retains the
observed run. It does not label that child cancelled or allow another start;
use `q` for shutdown.

Every `blocked` update retains the slot, including errors during automatic
restart. The panel waits for explicit slot release before loading a fresh
preview for an abandoned or expired intent; another explicit Enter is required.
A cancel rejection such as `not-queued` proves neither acceptance nor cancellation.
Termination uncertainty, automatic-policy changes, and automatic startup/worker
failures retain the blocked slot without an automatic retry or dismissal; use
`q` for the normal shutdown route. A global automatic failure is also shown
as a broker diagnostic when there is no queued request.
A changed work generation during confirmation requires a fresh inert proposal and
confirmation before replacing any successor. Previously consumed drafts and
widening grants are not silently reused or renewed. Scheduling previews use
fresh baseline permissions; cancel and reopen in Advanced to request a new
draft-bound widening grant. PreviewOnly remains a terminal no-mutation ceiling.
Automatic-resumption messages never replace the manual run's reported outcome.
Manual completion alone does not release a scheduling slot: the finished/failed
outcome remains visible while cleanup or automatic restart is pending or blocked.
Broker failure also keeps an unreleased scheduling slot blocked, including
after manual completion. Accepted runs and their terminal outcomes are retained
even when their notifications arrive before the confirmation response is handled.

These choices require the negotiated scheduling capability and the complete
broker scheduling API. Legacy, non-scheduling, foreign, or unverified owners
do not gain a Replace action; they retain an actionable busy/scope diagnostic.

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

### Simple (default)

| Key | Action |
| --- | --- |
| Up / Down / `j` / `k` | Select an agent or retained PR; selection scrolls into view |
| `Enter` / `Esc` | Open details / return to the list |
| `h` | Switch Live / History |
| `m` | Start Agent by PR ID, with the same explicit preview and start confirmations |
| `r` | Scan now: wake eligible current-launcher automatic workers, when available |
| `a` | Switch to Advanced; from Advanced, return to Simple |
| PageUp / PageDown, Up / Down | Scroll details, long previews, or help |
| `Ctrl+P` / `?` | Basic command palette / short help |
| `q` | Quit |

The sidebar remains visible beside open details when there is enough room.
Its brighter border marks list navigation; the main pane's border becomes
brighter when details are open. Up/Down selects sidebar rows before Enter and
scrolls details afterward, without adding pane-switching shortcuts. At 70
columns, or with fewer than four content rows available, Simple falls back
to a single pane. The automatic status, authority header, and basic controls
remain the same in both layouts.

Simple has no inspector, pane-focus controls, raw-event wall, role filter, or stale
management controls. Advanced-only keys provide a short `Press a for Advanced`
message. Switching mode returns to Live with all roles and clears open details
and transient filters; it does not restore explicitly dismissed instances or
hidden PR history. Mode changes are unavailable inside manual dialogs and
confirmation challenges. `a` in optional instructions is ordinary text.

Open details stay pinned to the exact agent instance or canonical repository/PR
identity as lists reorder. If that item leaves the view or is evicted, details
identify the original selection as unavailable rather than silently substituting
another row. Canonical History details work even without a retained agent instance.

Simple previews show the exact repository, PR, role, title, short commit,
complete allowed actions, and dynamic constraints. Long text wraps and scrolls;
the explicit `Enter: START` and `Esc: cancel` controls stay visible. Optional
instructions remain behind `p`. Advanced retains the full deny and widening
disclosures. Simple never invokes widening.

### Advanced

Press `a` from the main view for the detailed dashboard and all existing controls.

| Key | Action |
| --- | --- |
| `a` | Return to Simple, Live, all roles |
| Left / Right | Focus a visible pane |
| Up / Down / `j` / `k` | Select instance while the rail is focused |
| `Enter` | Drill from rail to narrative to current-run timeline |
| `Esc` / `b` | Dismiss overlay or move back toward the instance rail |
| `Tab` / `Shift+Tab` | Cycle all, reviewer, and review-handler roles |
| `f` / `Shift+f` | Cycle Live, Current session, and History views |
| `l` | Toggle Live only (the default) / Current session (including stale instances) |
| `Delete` | Dismiss the selected stale or finished instance across Watch restarts; retain logs and PR History |
| `Shift+Delete` | Restore dismissed instances and show Current session (also in `Ctrl+P`) |
| `x` / `Shift+x` | Hide the selected retained PR history row / restore all hidden PR history rows for this dashboard process |
| `/` | Filter PR history by number, title, author, repository, or outcome |
| Number then `Enter` | Jump to and restore a unique retained PR number |
| `m` | Start Agent by PR ID from any main view, when trusted policy is available |
| `r` | Scan now from a main view; in Settings, refresh the effective profile instead |
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
nothing. In Advanced, the focused pane is visible in both the header and pane border.

The default **Live only** view shows nonterminal instances with a heartbeat
within 20 seconds, including waiting, failed, or blocked agents that are still
heartbeating. Stale instances are excluded, without claiming they have exited.
In Advanced, press `l` to show **Current session**, which includes stale instances plus the
newest retained instance in each agent/session namespace group; press `l`
again to return to Live only. A completion event followed by `agent.waiting`
remains Live while heartbeats are recent. **History** contains
terminal retained runs whose lifecycle stopped or whose derived status is
completed. Overdue instances whose local PID is positively observed absent
are automatically removed from both Current and Live, including the newest
such row in a group. They remain available under **EXITED INSTANCES** in
Advanced History: select a row for its narrative/log path or press `e` for raw events.
Simple History shows these retained instances with human-readable outcomes and details.
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

`Delete` dismisses a stale or finished instance from Current session. Dismissals
survive Watch restarts in local display-preference files under
`%LOCALAPPDATA%\DevPilot\dashboard\dismissed-instances` on Windows, or
`$XDG_STATE_HOME/DevPilot/dashboard/dismissed-instances` (default
`~/.local/state`) elsewhere. A later heartbeat or agent-start event restores
the instance; replaying its old logs does not. `Shift+Delete` or **Restore
dismissed instances** in `Ctrl+P` restores these rows. Live agents cannot be
dismissed, and save failures leave the row visible with an error.
`--view-state-dir <path>` overrides only this display-preference directory.
Concurrent dashboards retain the newest dismissal watermark for each instance,
so a lagging window cannot undo a newer dismissal when old logs are replayed.
Storage is bounded to 5,000 dismissal records; reaching the limit reports an
error rather than silently evicting dismissals. Restore clears these records.

Dismissal never stops a process, changes locks or agent state, or deletes or
truncates event logs. PR History remains intact. Its existing `x`/`Shift+x`
hide/restore controls remain process-local; numeric jump restores a hidden
unique PR, while same-numbered PRs across repositories require repository selection.

The optional operator context is LF-normalized, rejects terminal control
characters, and is capped at 512 Unicode scalar values (including non-BMP
characters). It is sent only as bounded protocol data and is never placed in
argv, environment, logs, events, or diagnostics. Both previews show
the source commit, allowed actions, and dynamic constraints; Advanced additionally
shows mandatory denied actions. Policy digests and PR-state fingerprints remain bound and verified
by the protocol without dominating the operator view.
`source-changed`, `policy-changed`, `pr-state-changed`, `delivery-pending`,
`already-running`, broker/child failures, and cooperative/forced cancellation
are rendered with distinct safe detail.
For `already-running` / `state-contended`, another run of the selected role is
using this repository's durable state, possibly for a different PR. Wait for it
to finish, then retry, or use the explicitly confirmed current-launcher busy
choices when available. Removing a stale row does not release that lock.
The dashboard never bypasses authority or stops a process based on its PID.

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
- `dismissals.ts` persists per-instance display dismissals atomically, independently
  of PR History, agent state, work leases, and launch authority.
- `layout.ts` is a pure responsive decision function used by the SolidJS UI.
- `simple-view.tsx` supplies pure Simple presentation rows, identity-pinned list/details,
  and the scrollable manual panel without changing reducer or broker authority.
- `app.tsx` defaults to Simple and manages mode, selection, and confirmation input.
  Advanced renders focus-aware OpenTUI panes and overlays. At 120 columns it
  shows three panes, at 80-119 it overlays the inspector, and below 80 it uses
  one pane. The primary hierarchy is current phase, elapsed/model activity,
  candidate story, completion summary, and the current-run narrative.

The UI displays only bounded summaries. Unknown envelope or `data` fields are
accepted but are not rendered as unbounded raw content. Browser opening is
fail-closed: only credential-free `http:` and `https:` URLs are passed as a
process argument to a platform opener, never interpolated into a shell command.
