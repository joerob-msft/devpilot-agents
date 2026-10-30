# Owner production adapters: layer 2

`DevPilot.OwnerAdapters` is the read-only acquisition and evidence-input layer
for the generic `DevPilot.OwnerPipeline` facade. Production acquisition is the
canonical flow. Replay is a sealed input adapter to that same boundary; it is
not a benchmark case, corpus projection, or alternate pipeline.

```text
injected read-only provider -> canonical acquisition package
                                      |
sealed replay fixture ----------------+
                                      v
                         identical facade snapshot/evidence
```

## Immutable acquisition contract

`New-OwnerAcquisitionContract` validates and binds:

- repository and project identity plus subject pull request;
- exact source commit, target commit, and full target ref;
- authoritative rule repository, safe path, commit, section, SHA-256, and byte
  length;
- configuration and capability identity plus their digests;
- the acquisition file, byte, read, and diagnostic ceilings; and
- the facade's fixed `authority:preview-only` authorization partition.

The resulting request, limits, and facade binding are immutable typed objects.
Changing any bound identity produces a different facade binding. Provider
responses must echo the exact subject/head/target identity on every read.

## Injected provider boundary

`New-OwnerReadOnlyProviderAdapter` accepts one caller-supplied handler. The
production adapter invokes only four named operations:

1. `GetSubject`
2. `GetChangedFilesPage`
3. `GetRule`
4. `GetFile`

The module contains no provider client, credentials, MCP or CLI invocation, or
write operation. The injected handler is the host-specific trust boundary and
must itself expose read-only implementations. The adapter verifies the
operation allow-list before use, performs a final subject read to detect races,
and rejects stale or mixed identities.

Changed-file pagination must be complete, ordered, continuation-consistent,
and equal the subject's declared file denominator. Paths are normalized to
repository-relative `/` form. Rooted paths, traversal segments, control
characters, duplicate normalized paths, and case-ambiguous duplicates are
rejected.

## Evidence semantics

The common live/replay normalizer emits deterministic evidence units:

- `identity` contains the bound subject, head, target, configuration,
  capability, and source-artifact digest inventory;
- `rule` contains the authoritative rule identity and content state; and
- `file:NNNNNN` units contain ordinally sorted paths, rename/deletion/binary
  identity, changed spans, content state, lengths, truncation, and source
  digests.

Complete text and rule content is checked against its declared UTF-8 byte
length and SHA-256. For incomplete or truncated file responses, `byteLength`
and `sourceDigest` continue to describe the full source artifact while
`content` may contain only the returned prefix. File, span, or rule evidence
that is `incomplete`, `unknown`, binary, truncated, oversize, or unavailable
because a read/byte cap was reached remains an `unknown` evidence unit. Its
path still stays in the denominator. The adapter never drops partial units,
infers compliance, or turns missing coverage into a clear result.

Configured limits bound changed files, combined rule/file text bytes, provider
reads, and diagnostics. Adapter file and evidence-array ceilings are aligned
with the facade's evidence-unit and JSON-member ceilings, and an aggregate
canonical-node ceiling applies equally to live and replay packages. A known
file list can survive byte/read exhaustion or a provider that ignores its byte
hint by keeping unread or oversize files as explicit unknown units. An
oversize rule response likewise becomes explicit unknown rule evidence.
Each unknown file carries a bounded reason such as `binary`, `truncated`,
`spans-missing`, `oversize`, or `cap-exhausted`; the reason is evidence, not a
truncatable diagnostic. Acquisition fails closed when the subject denominator,
mandatory race check, identity, path, pagination, or fixture contract cannot
be trusted.

## Replay seal and equivalence

`New-OwnerReplayFixture` canonicalizes a JSON-shaped acquisition package and
creates an immutable corruption-evident checksum over its payload and the
production semantic-contract digest. The checksum is not a signature and does
not authenticate who produced the fixture. The trusted caller must obtain the
payload digest from an independently controlled fixture manifest or equivalent
reviewed configuration and pass it as `-ExpectedPayloadDigest`.

`New-OwnerReplayAcquisitionAdapter` rejects any fixture that does not match
that out-of-band pin, then verifies the internal checksum and sends the payload
through the same normalizer used by production. A caller that controls both the
fixture and its expected digest remains outside this module's trust guarantee;
no key, credential, HMAC state, or provenance service is introduced here.

Equivalent live and replay packages therefore produce byte-equivalent facade
snapshot/evidence envelopes and the same evidence digest. Array order supplied
by a provider cannot change file ordinals or the facade evidence digest.
Replay fixtures with a substituted payload, different semantics, broken
checksums, stale identities, or live/replay contract divergence are rejected.

## Explicit deferrals

This layer does not add capability or model execution, v1 compatibility,
relation-aware evidence contracts, parity runs, writer eligibility, delivery,
notifications, scheduling, queues, deployment switches, or cutover. It does
not read or migrate deployed reviewer state. Those remain separate later-layer
migration gates after parallel evidence acquisition has demonstrated stable
identity and replay equivalence.
