# Adding an agent

An agent is a loop. Each cycle it picks one unit of work, hands the work to a
coding model with a bounded prompt, verifies what came back, and records what
happened. The harness supplies everything that is not specific to the task:
process isolation, MCP sessions, state, notifications, and safety rails.

This guide describes what you have to write and, just as importantly, what you
should not.

## The three files

```
src/Agents/<agent-name>/
  Start-<AgentName>Agent.ps1     # the loop
  <cycle-name>.prompt.md          # what the model is asked to do
  testdata/                       # fixtures for offline self-checks
```

Nothing else. Configuration belongs to the consumer, not the agent.

## 1. The loop

Import the harness the same way the existing agent does. The co-located path is
tried first so the repo runs from a clone; the installed module is the fallback
so consumers can install from a feed.

```powershell
$coLocated = Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
if (Test-Path $coLocated) { Import-Module $coLocated -Force }
else { Import-Module DevPilot.AgentHarness -Force }
```

A cycle should do these things in this order:

1. **Select one item.** Never batch. If selection is ambiguous, skip and say so.
2. **Establish an isolated workspace** if the agent writes code — a worktree,
   not the current checkout.
3. **Build a runtime context** describing what the model may and may not do,
   derived entirely from config.
4. **Invoke the model** through the harness, never by calling the CLI directly.
5. **Verify.** Re-read state from the source of truth. Do not trust the
   response body.
6. **Record** the outcome to state before the next cycle starts.

### Two rules that are not optional

**Isolate the child process.** A coding CLI launched from inside an agent
session inherits environment variables that make it attach to the *parent*
session, where it will happily answer as the parent instead of doing the work.
The harness strips these, but only if you launch through it:

```powershell
Invoke-TimedProcess -FilePath $exe -ArgumentList $args -TimeoutSeconds $t
```

**Verify writes by re-reading.** Some hosts confirm a write in prose. Parsing
that as JSON throws *after* the write has landed, so the agent reports failure
for work that actually succeeded — and then retries it. Read the resulting
state back and assert on the field that changed:

```powershell
$after = Invoke-AgentMcpTool -Session $s -Tool 'get_pull_request' -Arguments $a
if (-not $after.autoCompleteSetBy) { throw 'auto-complete did not take effect' }
```

## 2. The prompt

The prompt describes the *task*, never the repository. Anything that begins
"in this repo we…" belongs in `repoConventions` in the consumer's config, which
the harness injects into the runtime context at cycle time.

Ask for a machine-readable marker at the end, and give it a nonce so output
from an earlier cycle can never be mistaken for this one:

```
When finished, emit exactly one marker:

<<<AGENT_RESULT:{nonce}>>>
{ "status": "updated", "summary": "...", "threadsAddressed": 3 }
<<<END>>>
```

Then parse it with `Get-AgentResultMarker`, which brace-matches the payload
anywhere in the output, tolerates an identical marker repeated by streaming,
and fails closed when two *different* markers appear.

## 3. Self-checks

Every agent ships a `-DryRun` suite that runs with no network, no host, and no
model. This is what CI runs on every pull request, and it is the only thing
standing between a refactor and a silently broken agent.

Cover at least:

- config loads and required keys are present
- the prompt file exists and contains the marker contract
- marker parsing: valid, absent, malformed, duplicated, conflicting
- any classifier logic, pinned against a fixture with expected output
- guard rails: each `-Enable*` switch is off by default

Classifier fixtures deserve particular care. Capture real input once, replace
every identity with a synthetic one, renumber the ids, and assert on exact
expected sets:

```powershell
$expectedActionable = @(1018,1019,1020,1022,1023,1024,1025,1026)
```

A fixture that only asserts a count will pass while classifying the wrong
items.

## Capabilities are opt-in

Every action with a side effect gets its own switch, defaulting to off, and
each one checks config before acting. An operator should be able to run the
agent with no switches and get a full dry cycle that touches nothing.

```powershell
[switch]$EnableCodeChanges,
[switch]$EnablePush,
[switch]$EnableThreadReplies
```

Validate the pairing between switch and config explicitly, and say which side
is wrong:

```powershell
if ($EnablePush -and -not $config.permissions.push.enabled) {
    throw '-EnablePush was passed but config.permissions.push.enabled is false.'
}
```

## What the harness already does

Do not reimplement these:

| Need | Function |
|---|---|
| Run a child process with isolation + timeout | `Invoke-TimedProcess` |
| Open / call / close an MCP session | `Open-AgentMcpSession`, `Invoke-AgentMcpTool` |
| Parse the result marker | `Get-AgentResultMarker` |
| Read and write agent state | `Get-JsonState`, `Save-JsonState` |
| Locate a prior coding session | `Find-CopilotSessionForBranch` |
| Create / reuse an isolated worktree | `New-AgentWorktree` |
| Notify a channel or a person | `Send-AgentNotification` |
| Find toolkit assets after install | `Get-DevPilotAgentPath` |
| Resolve the *consumer's* repo root | `Resolve-AgentRepositoryRoot` |

`Get-Command -Module DevPilot.AgentHarness` lists the rest.

## Before you open a pull request

```powershell
./tools/Test-NoEmployerSpecifics.ps1
./src/Agents/<agent-name>/Start-<AgentName>Agent.ps1 -DryRun -ConfigFile ./samples/<a-sample>.config.json
```

Then add a sample config demonstrating your agent's keys, and add the `-DryRun`
invocation to `.github/workflows/ci.yml`.
