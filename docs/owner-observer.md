# Owner observer

`OwnerObserver` is a read-only compatibility layer for comparing Owner reviewer
implementations. It does not instrument either implementation, start a model,
call a provider, mutate evidence, or publish comments or votes.

The shared version 2 Owner observation shape records implementation and capability
identity, pull request/head/target/rule binding, lifecycle state, checked,
violation, unknown and uncovered counts, stable findings and anchors when
available, attempts/model starts/latency, refusal or incomplete reasons,
provider writes, dedupe outcomes, operator intervention, source digests and
bounded validation errors. Missing evidence is the literal value `unknown`; it
is never converted to zero, completion or success.

## Observe deployed v1

Point the command at the external queue state root. The root must contain the
existing `keys/ledger.key`, signed `index/current.json`, referenced signed
artifact, and the referenced preview status under its external subject root.
Optional signed approved-comment intents and outcomes are read when present.

```powershell
./tools/Invoke-OwnerObservation.ps1 `
    -V1Root C:\private\owner-state `
    -HeadKey <64-lowercase-hex>
```

The key is read only to verify the existing canonical HMAC envelope. It is never
printed, copied, changed, or accepted on the command line. If a sanitized copy
relocates only the subject tree, use `-SubjectRootOverride` with its absolute
path. Artifact paths must remain inside the state root, run status files must be
direct children of `runs/<64-hex>/`, and links/reparse points are refused.

Do not place live evidence, state roots, keys, or command output in this
repository. The committed fixtures are synthetic and contain no live evidence.

## Observe a future v2

A future implementation can emit `src/OwnerObserver/schemas/owner-observation.v1.json`
directly or provide a thin adapter that does so. Read a local sanitized output:

```powershell
./tools/Invoke-OwnerObservation.ps1 `
    -NormalizedPath C:\observations\owner-v2.json
```

The normalized adapter validates the schema, bounds/redacts diagnostics, and
adds the source file digest when the artifact budget permits. If the producer
already used the full budget, the adapter preserves the bounded artifacts and
marks provenance incomplete. It performs no inference for omitted detail; v2
producers must state `unknown`.

## Compare

Parity input files are normalized observations:

```powershell
./tools/Invoke-OwnerObservation.ps1 `
    -BaselinePath C:\observations\owner-v1.json `
    -CandidatePath C:\observations\owner-v2.json
```

The report is deterministic: versioned semantic finding keys are sorted and
classified as retained, lost or new; canonical repository paths and spans are
compared while raw representations remain hashed audit evidence; provider
markers are reported separately; and measured zero is distinct from
unavailable or not-measured telemetry.
