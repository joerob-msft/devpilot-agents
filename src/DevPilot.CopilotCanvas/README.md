# DevPilot Operations canvas (prototype)

This is a GitHub Copilot app canvas extension for watching DevPilot agents and
staging a PR review. Setup, design and the long-term requirement are documented
in the *Copilot app canvas (prototype)* section of
[`src/DevPilot.Dashboard/README.md`](../DevPilot.Dashboard/README.md).

- `extension.mjs` wires the canvas with `@github/copilot-sdk/extension`. Never
  use `console.log` in it, because stdout is the JSON-RPC channel.
- `canvas-server.mjs` is plain Node with no SDK dependency. It handles bridge
  discovery, repository and worktree matching, the per-instance loopback server,
  and the proxy.
- `ui/` holds the static page. It uses Primer theme tokens with fallbacks.

Install with `tools\Install-DevPilotCanvas.ps1`.
