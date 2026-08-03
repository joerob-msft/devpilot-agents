# DevPilot Agents

A portable harness for **autonomous, wrapper-governed coding agents** driven by
GitHub Copilot CLI.

Agents run unattended on a developer machine, pick up work from a pull-request
host, reason about it, and make bounded changes. The design principle is that
the **model reasons; the wrapper decides**. A trusted PowerShell wrapper selects
and binds the work, owns all state, performs every external write, and validates
everything the model returns. The model never selects its own work and never
writes to the PR host directly.

> **Status: pilot.** One agent (`review-handler`) is implemented and running
> against Azure DevOps. Interfaces will change.

---

## Why a wrapper

Letting a model drive an autonomous loop directly means trusting it with
selection, authority, and state. This design deliberately does not:

| Concern | Owned by |
|---|---|
| Which PR to work on | Wrapper (deterministic selection) |
| What the agent may do | Wrapper (code-defined tool ceiling; config may narrow, never widen) |
| Every PR / pipeline write | Wrapper |
| Durable state and audit log | Wrapper |
| Reading code, reasoning, editing | Model |

The model's only channel back to the wrapper is a strict, nonce-bound result
marker. Anything else it prints is ignored.

---

## Repository layout

```text
src/
  DevPilot.AgentHarness/     # the shared, provider-agnostic module
  Agents/
    review-handler/          # an agent: script + prompt + fixtures
samples/                     # example configs for real repositories
tools/                       # repo hygiene checks
docs/                        # how to add an agent
```

**Consumers keep only a config file.** Nothing employer-, repository-, or
person-specific lives in this repo outside `samples/` — a CI check enforces that
(`tools/Test-NoEmployerSpecifics.ps1`).

---

## Quick start

```powershell
# 1. Load the harness (from a checkout; a published module is planned)
Import-Module ./src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1

# 2. Copy a sample config into the repository you want the agent to work on
#    e.g. <your-repo>/.github/copilot/agents/review-handler.config.json

# 3. Prove it works offline — no network, no Copilot process
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -DryRun `
    -ConfigFile <your-repo>/.github/copilot/agents/review-handler.config.json

# 4. First live cycle. Every mutating capability is OFF by default:
#    this analyses a PR and writes nothing.
./src/Agents/review-handler/Start-ReviewHandlerAgent.ps1 -Once `
    -ConfigFile <your-repo>/.github/copilot/agents/review-handler.config.json `
    -OperatorAlias <your-alias>
```

The config's **location** tells the agent which repository to operate on, so it
must live inside that repository.

---

## The agents

| Agent | Watches | Does |
|---|---|---|
| `review-handler` | Your own open PRs | Finds reviewer feedback you have not answered, resumes the coding session where the code was written, makes the fix, replies, pushes, optionally requeues validation and sets auto-complete |
| `reviewer` *(planned)* | Other people's PRs | Posts advisory findings, optionally signs off |

---

## Safety model

Non-negotiable, and enforced in code rather than prose:

- **Code-defined tool ceiling.** Config can narrow it; nothing can widen it.
- **Mandatory denies.** PR-write and pipeline-write are denied to the model
  unconditionally — the wrapper performs those itself.
- **Every mutating capability is a separate switch, defaulting OFF.** Pushing
  requires two independent flags.
- **Protected branches** (`main`, `master`, `dev`, `release/*`) are rejected in
  the wrapper before push tooling is granted, not merely discouraged in a prompt.
- **All PR text is untrusted input.** Comment bodies never reach the model as
  instructions; it receives a structured metadata digest instead.
- **Writes are verified by re-reading state**, never by trusting a response —
  some hosts confirm writes in prose, and parsing that as JSON throws *after*
  the write has already landed.
- **`-DryRun` self-checks are mandatory** and run offline.

---

## Extending

Adding an agent means adding a folder under `src/Agents/`, containing a wrapper
script, a cycle prompt, and any fixtures. The harness supplies everything else.

See [`docs/adding-an-agent.md`](docs/adding-an-agent.md).

---

## Known limitations

- **Azure DevOps only, today.** A provider abstraction for GitHub is designed
  but not implemented. Thread resolution, auto-merge, and validation-run lookup
  differ enough between hosts to need real adapters.
- **The local-validation tool ceiling is code-defined.** .NET and MSBuild repos
  work out of the box; adding another build ecosystem (npm, cargo, gradle)
  requires a toolkit change and a security review — deliberately, since the
  ceiling is a security boundary.
- **Telemetry is local JSONL.** Central aggregation and a dashboard are planned.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `./tools/Test-NoEmployerSpecifics.ps1`
and the agent `-DryRun` suite before opening a pull request.

## License

[MIT](LICENSE)
