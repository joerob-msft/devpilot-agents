# DevPilot Operations Dashboard

A read-only terminal operations console for observing DevPilot reviewer and
review-handler instances. It consumes the per-instance JSONL event streams and
never invokes, stops, retries, promotes, or otherwise controls an agent.

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
```

The repository launcher intentionally does not install dependencies:

```powershell
.\tools\Start-DevPilotDashboard.ps1 -StateDir C:\DevPilot\state
.\tools\Start-DevPilotDashboard.ps1 `
  -StateDir C:\ReviewerState,C:\HandlerState `
  -EventLogPath C:\captures\reviewer.jsonl
```

For direct debugging:

```powershell
npm start -- --state-dir C:\DevPilot\state --event-log C:\captures\events.jsonl
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
| Arrow keys / `j` / `k` | Select instance |
| `Enter` | Open detail |
| `Esc` / `b` | Dismiss overlay or return to the instance rail |
| `Tab` / `Shift+Tab` | Cycle all, reviewer, and review-handler roles |
| `i` | Inspector |
| `e` | Bounded events overlay; Left/Right changes filter |
| `w` | Next failed, blocked, or diagnostic-bearing instance |
| `Ctrl+P` | Read-only command palette |
| `?` | Help |
| `q` | Quit |

## Architecture

- `domain.ts` validates and bounds the additive event envelope.
- `tailer.ts` discovers streams and maintains one rotation-safe byte cursor per
  file. Complete malformed lines become bounded diagnostics; partial lines stay
  buffered until a newline arrives.
- `reducer.ts` deduplicates by instance sequence, surfaces gaps, derives
  lifecycle and attention state, and retains at most 500 timeline events per
  instance.
- `layout.ts` is a pure responsive decision function used by the SolidJS UI.
- `app.tsx` renders OpenTUI panes and overlays. At 120 columns it shows three
  panes, at 80-119 it overlays the inspector, and below 80 it uses one pane.

The UI displays only bounded summaries. Unknown envelope or `data` fields are
accepted but are not rendered as unbounded raw content.
