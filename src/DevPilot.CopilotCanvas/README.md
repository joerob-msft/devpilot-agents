# DevPilot Operations canvas

This is a GitHub Copilot app canvas extension that starts, watches and stops a
repository's DevPilot Golden watch and stages PR reviews. Setup, design and the
safety model are documented in the *Copilot app canvas* section of
[`src/DevPilot.Dashboard/README.md`](../DevPilot.Dashboard/README.md).

- `extension.mjs` wires the canvas with `@github/copilot-sdk/extension`. Never
  use `console.log` in it, because stdout is the JSON-RPC channel.
- `canvas-server.mjs` is plain Node with no SDK dependency. It handles bridge
  discovery, repository and worktree matching, the per-instance loopback server,
  the proxy, and the human-gated watch Start/Stop routes.
- `watch-launcher.mjs` picks the Start entrypoint and tails its launch log. It
  prefers the repository's own `Start-DevPilot.ps1 -CanvasBridge -Headless`
  when that script declares both switches, which it checks by reading the
  parameters without running the script. Otherwise it falls back to the recorded
  toolkit's `Watch-DevPilotAgents.ps1 -Golden -Headless -CanvasBridge`. Previews
  add `-WhatIf`.
- `ui/` holds the static page. It uses Primer theme tokens with fallbacks. It
  has Live (default) and History tabs, a single **Start watch…** → plan →
  **Confirm start** flow when no watch runs, and updates rows in place so
  polling never steals focus or scroll. Polling pauses while the canvas is
  hidden and backs off when idle.

Install with `tools\Install-DevPilotCanvas.ps1`, which also records the
fallback `toolkit.json`. Tests: `node --test tests\CopilotCanvas.Tests.mjs`.

## Error surfacing

- Failed or deferred runs show the real cause (`failureDetail`), when it happened, the next try, **View failure log** (read through the bridge only for a path an agent event recorded *and* that resolves inside a watch `--state-dir`, capped at 64 KiB, credential-looking lines redacted) and **Copy error**.
- Agent health comes from `agent.health` events (falling back to 3+ consecutive failed/deferred `work.completed` for older agents): red banner when failing, amber chip when stuck, and the canvas/tab title reads `⚠ DevPilot Operations · Reviewer failing`. `get_status` includes bounded health.
- History and Live rows carry a pill: Needs you, Will retry, Reviewed or Stuck. Stuck PRs offer **Skip this PR** (confirmed by the user; the bridge resolves repository and commit from recorded events and writes `<watch StateDir>/<role>/skipped-prs.json`), **Review again…** and **View last failure log**. Agents cannot skip.
- Teams delivery problems show `Teams: N queued · <reason>` and a warning banner after 3 failures since the last delivery.
- A failed canvas launch shows the `DevPilot model preflight failed` line (or the last Error/Exception line) above the log tail.
