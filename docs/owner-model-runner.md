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

## Real provider

`New-OwnerCopilotCliModelProvider` pins the native Copilot CLI executable,
its SHA-256 digest, and the investigated ACP server argument contract.
`New-OwnerModelProcessRunner` requires the provider plus the explicit
`-EnableRealLaunch` switch. Construction runs the same model-free preflight as
`Test-OwnerModelProviderPreflight` and refuses launch if any invariant is
unproven.

The intended server-start tool ceiling remains the same impossible sentinel:

```text
--acp
--stdio
--available-tools=__devpilot_no_such_tool_7f2c17a64a3e4d6b__
--disable-builtin-mcps
--no-custom-instructions
--no-remote
--no-remote-export
--no-ask-user
--disallow-temp-dir
```

GitHub's documented ACP server uses Agent Client Protocol v1, JSON-RPC 2.0,
and newline-delimited JSON over child stdin/stdout. The server-start
`--available-tools` option applies to every ACP session. Copilot CLI's
versioned permission help states that this option disables every other tool
and decides which tools the model can see. The provider supplies a non-empty,
code-defined impossible sentinel rather than an ambiguous empty option value.
With built-in MCPs disabled and a clean Copilot home containing no configured
servers, plugins, agents, or instructions, no registered tool can match that
sentinel. Permission-only flags are not used as a substitute for availability
filtering. Because preflight never creates a session, it does not claim to have
observed the resulting session tool set. GitHub documents
`--available-tools`, `--excluded-tools`, and reasoning effort as ACP
session-wide server settings, but does not document every other hardening flag
as ACP-session-scoped. Preflight therefore reports
`effectiveTools: not-proven-acp-session-scope` rather than an empty array.

The model-free exchange is exactly one `initialize` request with
`protocolVersion: 1` and false client filesystem, terminal, and terminal-auth
capabilities, followed by one bound `initialize` result. A usable prompt flow
would additionally require `session/new`, streamed `session/update`
notifications, and `session/prompt`; this layer intentionally sends none of
those messages. The protocol sources are the
[GitHub Copilot CLI ACP server reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server)
and the [ACP v1 protocol](https://agentclientprotocol.com/protocol/v1/overview).

ACP solves the argv exposure identified by the prompt-mode layer: prompt bytes
would travel in a `session/prompt` message on the framed stdin protocol rather
than in `--prompt`. It does not yet satisfy the complete confidentiality
boundary. The isolated native launcher's bundled 1.0.79 ACP runtime advertises
`loadSession` and `sessionCapabilities.list`; ACP defines these as restoring
and enumerating conversation history. Copilot's documented ACP options provide
no disable-persistence or disable-history switch, the observed server does not
advertise `session/delete`, and the CLI exposes no documented ACP memory-off
control. ACP support is also documented as public preview and subject to
change. A private bounded prompt therefore cannot be proven absent from
session storage or later session replay/export surfaces.

The real launcher remains unavailable with
`acp-atomic-process-containment-unavailable` on Windows before starting the ACP
server. `System.Diagnostics.Process` cannot create the child suspended, so a
child could otherwise spawn outside the kill-on-close job before assignment.
On non-Windows platforms the next blocker is
`copilot-cli-publisher-identity-unproven`, because this layer does not yet have
a supported publisher-attestation equivalent to Windows Authenticode. No path
sends `session/new` or `session/prompt`, places bounded stimulus in argv, or
starts a model. A future supported ACP mode must provide both atomic
containment and publisher proof, then disable session persistence,
history/list/load/export, and memory before this gate can open.

For executable providers, each attempt gets a fresh directory outside the
repository. That directory is also the child home, application-data root, and
temporary root. The child environment starts empty and contains only bounded
OS bootstrap variables, isolated directory variables, and fixed safety
settings. The real-provider policy would copy only the selected credential to
`COPILOT_GITHUB_TOKEN`; preflight never injects it, and the unavailable real
path never starts. GitHub, Azure, ADO, provider, proxy, telemetry-exporter, and
unrelated secret variables are not inherited. Credential values and model
output text are never logged.

## Process boundary

The deterministic fake provider adapter closes stdin, drains stdout and stderr
asynchronously, enforces total, activity, and per-call deadlines, bounds bytes
and lines, extracts one deterministic marker, validates exact nonce/input/
subject/model bindings, and contains the process tree with the shared Windows
job or Unix process-group helpers.

The ACP preflight opens stdin only for one bounded `initialize` request. It
advertises no client filesystem, terminal, terminal-authentication, or
elicitation capability; accepts exactly one bound JSON-RPC response; rejects
duplicate JSON properties, extra messages, malformed UTF-8/JSON, version or ID
mismatch, floods, disconnects, descendants, and timeouts; then closes stdin
and requires deterministic server termination. Raw invalid stdout and stderr
are never returned. Only their SHA-256 digests are reported.

Telemetry contains provider and invocation contract identity, the input digest,
nonce, opaque subject binding, per-attempt timing, process/model-start state,
exit/timeout/refusal, stdout/stderr digests, the exact successful response bytes
as canonical base64, and the effective tool/environment policy. Failed stderr
and unvalidated stdout are represented only by digests. A real attempt reports
model starts as `unknown` unless a valid bound model response proves one;
offline replay and deterministic fake processes report measured zero.

`New-OwnerModelFakeProvider` materializes the bounded envelope in a user-private
file inside the isolated attempt directory and passes only that opaque path in
argv. It exercises the same out-of-process supervision and parser with closed
stdin and no credential, network, or provider call. Tests and CI use only this
fake and offline replay.

## One-command preflight

```powershell
./tools/Test-OwnerModelLauncher.ps1 -Model gpt-5.6-sol `
    -CredentialEnvironmentName GH_TOKEN
```

When `Get-Command copilot` resolves to an npm shell shim rather than the native
CLI executable, pass the installed native binary with `-CopilotPath`. The
launcher rejects interpreter shims because its strict child environment does
not inherit an ambient interpreter search path.

The preflight resolves the native executable, records its SHA-256 digest, and
on Windows verifies its Authenticode publisher as GitHub, Inc. Before a safe
launch it copies the pinned bytes to the private attempt root, re-verifies the
staged digest and publisher, and launches only that private copy. It uses a
clean home and environment to verify credential presence and supported shape,
every documented CLI option, the no-tools semantics in `help permissions`, and
the hardened option-value syntax. It runs `--version`, `--help`,
`help permissions`, one argument parse terminated by the `version` subcommand,
and one ACP
v1 `initialize` exchange. It does not create a session or send a prompt;
`modelCalls` and `providerWrites` remain zero. The reported CLI version is the
isolated runtime selected by the native executable and can differ from an
ambient invocation that reuses a previously downloaded package. The ACP
`agentInfo.version` must exactly match that isolated `--version` result.

On Windows the current process API cannot bind the child to the job before its
first instruction. The machine preflight therefore stops before any executable
launch and reports `acp-atomic-process-containment-unavailable`. The documented
1.0.79 capability result above came from the bounded investigation probe that
motivated this fail-closed implementation; production preflight does not repeat
that unsafe start.

No ACP SDK dependency was added. PowerShell 7 already provides the process,
UTF-8, JSON, and `System.Text.Json` primitives needed for this one-message
preflight. A full prompt client is intentionally absent while confidentiality
is blocked.

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
