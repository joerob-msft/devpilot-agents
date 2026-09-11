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

`New-OwnerCopilotCliModelProvider` pins the supported Copilot CLI prompt-mode
contract. `New-OwnerModelProcessRunner` requires the provider plus the explicit
`-EnableRealLaunch` switch. Construction runs the same no-call preflight as
`Test-OwnerModelProviderPreflight` and refuses launch if any invariant is
unproven.

The effective model-visible tool set is literally empty:

```text
--available-tools=__devpilot_no_such_tool_7f2c17a64a3e4d6b__
--disable-builtin-mcps
--no-custom-instructions
--no-remote
--no-remote-export
--no-ask-user
--disallow-temp-dir
```

Copilot CLI's versioned permission help states that `--available-tools`
disables every other tool and decides which tools the model can see. The
provider supplies a non-empty, code-defined impossible sentinel rather than an
ambiguous empty option value. With built-in MCPs disabled and a clean Copilot
home containing no configured servers or plugins, no registered tool can match
that sentinel, so the effective set is empty. The provider verifies the help
contract, required flags, an isolated CLI version of at least 1.0.79, process
containment, and exact argument immutability. It does not use permission-only
flags as a substitute for availability filtering. There is no harmless
fallback tool set and no widening path.

The current CLI exposes prompt text only through `--prompt`, which places the
bounded source stimulus in process arguments visible to local process
enumeration. Closed stdin is a required boundary, and the CLI has no supported
private-file prompt option. The real launcher therefore remains unavailable
with `copilot-cli-confidential-prompt-channel-unavailable`; it does not place
the stimulus in argv or start a model. A future supported confidential prompt
channel must preserve the same no-tools contract before this gate can open.

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

The contained provider adapter closes stdin, drains stdout and stderr
asynchronously, enforces total, activity, and per-call deadlines, bounds bytes
and lines, extracts one deterministic marker, validates exact nonce/input/
subject/model bindings, and contains the process tree with the shared Windows
job or Unix process-group helpers.

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

The preflight uses a clean home and environment to verify executable identity,
credential presence and supported token shape, every required CLI option in the
help contract, the no-tools semantics in `help permissions`, and the hardened
option-value syntax. It runs `--version`, `--help`, `help permissions`, and one
full hardened argument-prefix parse terminated by `--version`; `modelCalls` and
`providerWrites` remain zero. After those checks it reports
`copilot-cli-confidential-prompt-channel-unavailable`, because the supported
CLI prompt transport is argv-only. It does not validate provider entitlement
or endpoint acceptance and never performs a model request. The reported CLI
version is the isolated native executable version used by the launcher and can
differ from a PATH shim's ambient version.

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

The launcher does not run the preserved parity cohort. Prospective real-model
parity remains blocked on a supported confidential, closed-stdin-compatible
prompt channel. Writer compatibility, deployment, notifications, votes,
comments, and cutover remain separate later gates.
