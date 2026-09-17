# Contributing

## Before you open a pull request

Run the fast baseline checks and the component checks relevant to your change.
The commands below mirror `.github/workflows/ci.yml`; use targeted selectors
locally rather than running every suite for a small change.

```powershell
# 1. No employer-, repo-, or person-specific values outside samples/
./tools/Test-NoEmployerSpecifics.ps1

# 2. The agent's own self-check suite
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -DryRun `
    -ConfigFile ./samples/handler-ado.config.json
./src/Agents/reviewer/Start-ReviewerAgent.ps1 -DryRun `
    -ConfigFile ./samples/reviewer-ado.config.json
```

## Build and test

Use PowerShell 7. Node components require Node 24 or newer. PowerShell suites use
Pester 5 (CI pins 5.7.1); linting uses PSScriptAnalyzer. Restore dependencies with
`npm ci` in the component directory on initial setup or after its lockfile changes.
No Copilot authentication or live model calls are needed for the offline suites.

| Change area | Commands from the repository root |
| --- | --- |
| Fleet build | `npm run build --prefix .\src\DevPilot.Fleet` |
| Fleet offline suite, including build | `npm test --prefix .\src\DevPilot.Fleet` |
| Fleet bridge/protocol | `Invoke-Pester -Path .\tests\FleetBridge.Tests.ps1,.\tests\FleetProtocol.Tests.ps1,.\tests\FleetOutputLimit.Tests.ps1,.\tests\FleetCliStream.Tests.ps1` |
| Dashboard build | `npm run build --prefix .\src\DevPilot.Dashboard` |
| Dashboard logic suite, including build | `npm test --prefix .\src\DevPilot.Dashboard` |
| Specific harness/agent behavior | `Invoke-Pester -Path .\tests\<relevant-suite>.Tests.ps1 -Output Detailed` |
| Complete PowerShell suite | `Invoke-Pester -Path .\tests -Output Detailed` |
| PowerShell lint, CI severity | `Invoke-ScriptAnalyzer -Path .\src -Recurse -Severity Error` |
| Provider fixtures | `.\tools\Test-Provider.ps1` |
| Module manifest | `Test-ModuleManifest .\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1` |

Some PowerShell integration suites depend on built dashboard artifacts: restore
and build `src\DevPilot.Dashboard` before running the complete PowerShell suite.
Dashboard renderer/terminal changes also need `npm run test:renderer` and
`npm run test:pty` from that component directory, plus
`Invoke-Pester -Path .\tests\DispatchStartup.Tests.ps1` from the repository root.
CI additionally covers platform matrices; a single local operating system does
not replace those runs.

Fleet's `test:live` is separate, opt-in, and consumes model usage. See
[Fleet development and boundaries](docs/fleet-poc.md#development); do not enable
live execution as part of the default offline workflow.

## Principles

**Keep the toolkit generic.** Anything specific to one organization, repository,
or person belongs in a consumer's config file. The leak check enforces this, and
it is the property that makes the toolkit reusable at all.

**Prefer failing closed.** When something is ambiguous — a malformed response, a
missing MCP server, an unverifiable write — stop and say so. A cycle that does
nothing is always better than one that does the wrong thing to someone's
repository.

**Verify writes by re-reading state.** Do not infer success from a response
body. Some hosts confirm writes in prose, and parsing that as JSON throws
*after* the write has already landed — which reports failure for work that
actually succeeded.

**Every behavioural fix gets a self-check.** The suite exists because these
failures are silent: an agent that quietly does nothing looks identical to an
agent with nothing to do. If you fix a bug, add the check that would have caught
it, and prove the check fails without your fix.

**Treat all pull-request content as untrusted.** It is attacker-controllable in
the general case.

## Adding an agent

For a full harness-backed agent with its own selection/execution loop, see
[Adding an agent](docs/adding-an-agent.md). For a tool-disabled analysis role
defined only by a prompt and manifest entry, see
[Fleet role authoring](docs/fleet-poc.md#create-an-agent-without-changing-toolkit-code).
