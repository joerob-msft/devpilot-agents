# Owner bounded model runner: layer 4

`DevPilot.OwnerModelRunner` implements the injected judgment-only runner used
by `DevPilot.OwnerCapability`. It remains preview-only and does not schedule,
persist, deliver, or authorize findings.

The runner receives only the layer-3 bounded capability request. The process
envelope adds an unpredictable nonce, canonical input digest, opaque subject
binding, and a literal empty tool ceiling. The response marker can contain only
opaque execution-unit references and `compliant`, `violation`, or `unknown`
judgments. Layer 3 continues to own subject and head identity, rule provenance,
eligibility, anchors, grouping, summaries, findings, and all write authority.

## Process boundary

The contained child adapter closes stdin, drains stdout and stderr
asynchronously, enforces total, activity, and per-call deadlines, bounds bytes
and lines, extracts one deterministic marker, validates exact nonce/input/
subject bindings, and contains the process tree with the shared Windows job or
Unix process-group helpers. Output text is never included in telemetry.

The repository's current model CLI does not provide a proven literal
read-only/no-tools mode. Consequently, the public process adapter is
unconditionally unavailable. Generic process fixtures exercise a private
test-child seam instead. This layer does not widen CLI permissions to obtain a
live result.

## Offline replay

Replay fixtures contain only sanitized response bytes plus opaque binding
values. Replay sends those exact bytes through the same marker parser and
schema validator as the child adapter. It has no executable, provider, network,
tool, or writer surface and records zero model starts.

Malformed, omitted, duplicate, timed-out, or unknown unit responses degrade
that unit to `unknown`; valid sibling units remain usable. A nonce, input
digest, or opaque subject-binding mismatch atomically fails that execution.
Layer 3 can project sanitized attempts, latency, starts, and refusal outcome
through the existing `owner-observation.execution` shape.

## Deferred next layer

The next layer should add a parallel scheduler/orchestrator with a separate
preview state root and a sustained parity cohort. Real model enablement,
writer compatibility, deployment, notifications, votes, comments, and cutover
remain separate later gates.
