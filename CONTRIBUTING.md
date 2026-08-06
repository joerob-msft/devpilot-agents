# Contributing

## Before you open a pull request

Both checks are fast and run offline:

```powershell
# 1. No employer-, repo-, or person-specific values outside samples/
./tools/Test-NoEmployerSpecifics.ps1

# 2. The agent's own self-check suite
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -DryRun `
    -ConfigFile ./samples/handler-ado.config.json
```

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

See [docs/adding-an-agent.md](docs/adding-an-agent.md).
