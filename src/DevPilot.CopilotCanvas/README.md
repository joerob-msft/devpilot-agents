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
- `watch-launcher.mjs` runs the recorded toolkit's
  `Watch-DevPilotAgents.ps1 -Golden -Headless -CanvasBridge` (`-WhatIf` for the
  launch plan preview) and tails its launch log.
- `ui/` holds the static page. It uses Primer theme tokens with fallbacks.

Install with `tools\Install-DevPilotCanvas.ps1`, which also records
`toolkit.json`. Tests: `node --test tests\CopilotCanvas.Tests.mjs`.
