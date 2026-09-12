# Owner bounded model runner: no-tools launcher layer

`DevPilot.OwnerModelRunner` implements the injected judgment-only runner used
by `DevPilot.OwnerCapability`. It remains preview-only and does not schedule,
persist, deliver, notify, vote, comment, or authorize findings.

The runner receives only the layer-3 bounded capability request. The process
envelope adds an unpredictable nonce, canonical input digest, opaque subject
binding, and a literal empty tool ceiling. The response marker can contain only opaque execution-unit references,
`compliant`, `violation`, or `unknown` judgments, and one optional bounded
single-line rationale. Layer 3 continues to own subject and head identity,
rule provenance, eligibility, anchors, grouping, summaries, findings, and all
write authority.

## Supported Copilot CLI prompt provider

`New-OwnerCopilotCliModelProvider` uses ordinary supported Copilot CLI prompt
mode. `New-OwnerModelProcessRunner` still requires explicit
`-EnableRealLaunch`; construction first runs the model-free
`Test-OwnerModelProviderPreflight`.

The launcher passes only the bounded semantic envelope and response contract
through `--prompt`. It never places a credential in the prompt or argument
list. The prompt is capped at 12 KiB and telemetry records
`promptTransport: argv` and `localProcessMetadataExposure: true`. This is an
accepted residual risk: the bounded source stimulus may be transiently visible
to same-user process inspection, endpoint monitoring, or administrators.

The fixed CLI policy uses:

```text
--available-tools=__devpilot_no_such_tool_7f2c17a64a3e4d6b__
--allow-all-tools
--disable-builtin-mcps
--no-custom-instructions
--no-remote
--no-remote-export
--no-ask-user
--disallow-temp-dir
```

`--allow-all-tools` is present only because prompt mode is noninteractive.
Copilot CLI's versioned permission help states both that `--available-tools`
disables all other tools and that permission flags do not expose filtered
tools. Preflight requires both statements and reports `effectiveTools: []`.
The isolated home and empty working directory provide no plugins, agents,
custom instructions, repository, resume state, memory, MCP configuration, or
additional directories.

Each attempt gets a fresh private home, application-data, working, and
temporary directory outside the repository. The child environment starts
empty and receives only the strict OS bootstrap allowlist, fixed safety
settings, and the selected credential mapped to `COPILOT_GITHUB_TOKEN`. The
private directory names retain 128 bits of randomness in a compact path-safe
encoding so Windows leaves room for Copilot's per-session SQLite files. The
pinned native executable is copied into the attempt directory and its digest
and Windows GitHub publisher identity are rechecked before launch. Stdin is
closed; stdout and stderr are drained with byte, line, activity, call, total,
and attempt limits. The shared process containment terminates the full tree on
timeout or cleanup immediately after start. Atomic pre-start containment is
not required and is reported as false.

The response must contain exactly one marker with exact nonce, input digest,
opaque subject, model, and execution-unit bindings. Invalid output and stderr
are retained only as digests. Telemetry reports model-call accounting,
provider writes as zero, the empty effective tool set, response provenance,
and no raw prompt.

Run the model-free preflight with:

```powershell
./tools/Test-OwnerModelLauncher.ps1 -Model gpt-5.6-sol `
    -CredentialEnvironmentName GH_TOKEN
```

It checks the native executable, publisher, isolated CLI version, all required
flags, no-tools semantics, syntax, credential shape, and process containment.
It performs no prompt and reports `modelCalls: 0` and `providerWrites: 0`. The
isolated embedded 1.0.79 runtime is accepted because this exact prompt/no-tools
interface is validated; an ambient invocation may report a newer compatible
runtime. ACP initialization remains internal diagnostic coverage and is not
the production transport for this layer.

## Offline replay

Replay fixtures contain only sanitized response bytes plus opaque binding
values. Replay sends those exact bytes through the same marker parser and
schema validator as the child adapter. It has no executable, provider, network,
tool, or writer surface and records zero model starts. Version-1 recorded
markers remain readable; new process responses use version 2 with model
identity binding.

Malformed, omitted, duplicate, timed-out, or unknown unit responses degrade
that unit to `unknown`; valid sibling units remain usable. A nonce, input
digest, or opaque subject-binding mismatch atomically fails that execution.
Layer 3 can project sanitized attempts, latency, starts, and refusal outcome
through the existing `owner-observation.execution` shape.

The launcher does not run the preserved parity cohort. No real model validation
call is permitted while ACP session persistence and memory controls remain
unproven. Writer compatibility, deployment, notifications, votes, comments,
and cutover remain separate later gates.
