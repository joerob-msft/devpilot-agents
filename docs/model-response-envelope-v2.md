# Generalist model response envelope v2

The v1 result marker asked the generalist for one JSON object that carried both
the model's review *and* the wrapper's own bindings — pull request id, repository
id, project, reviewed source commit, and the anti-replay `nonce` — and rejected
the whole object if any single field was missing.

That is correct, and it is also brittle in one specific way that costs real
review passes. A model that writes a complete, well-formed review and then drops
the last field of the object loses everything: no findings, no summary, no vote,
and — worse — no record that the reviewer answered at all. The pass disappears
from the verifier census, which is indistinguishable from the reviewer never
having run. Observed repeatedly with `claude-opus-5`, which emits valid JSON
with every field except the trailing `nonce`.

V2 separates the two things v1 conflated:

| | v1 | v2 |
| --- | --- | --- |
| proof of liveness | a `nonce` field inside the payload | a standalone first line |
| model-owned content | mixed with wrapper bindings | payload carries content only |
| missing nonce | whole pass lost | pass kept as evidence, cannot vote |

## The model contract

Two independent lines. The order is fixed; the model emits the nonce line first.

```text
REVIEWER_NONCE_V2: 3f9c1a7b0e5d2846bc17f4a908e3d5b62c40
REVIEWER_PAYLOAD_V2: {"schemaVersion":2,"reviewedSourceCommit":"<40 hex>","findings":[...],"recommendedVote":"approveWithSuggestions","summary":"..."}
```

The payload object contains **exactly** these five keys and nothing else:

- `schemaVersion` — must be `2`.
- `reviewedSourceCommit` — 40 lowercase hex, the first bound field, and it must
  equal the commit the wrapper actually sent.
- `findings` — array; each item has exactly `severity`, `filePath`, `line`,
  `comment`.
- `recommendedVote` — `approve`, `approveWithSuggestions`, `waitForAuthor`, or
  `none`.
- `summary` — string.

No `prId`, no `repositoryId`, no `project`, no hashes, no `nonce`. Those are
wrapper-owned. The wrapper knows them; asking the model to repeat them creates
exactly one thing — an opportunity for the model to get them wrong — and buys
nothing, because the wrapper would never trust the model's copy over its own.

The model may repeat an identical nonce line and an identical payload in a later
assistant message. It may not emit a *different* one.

## Extraction

Extraction reads the ordered, non-ephemeral `assistant.message` events of the CLI
stream and nothing else. Prompt echoes, tool calls, tool results, and stderr are
never a source. This matters: a pull request whose own diff contains the literal
text `REVIEWER_PAYLOAD_V2: {...}` would otherwise be able to speak as the
reviewer, because that text arrives back through a tool result.

- All assistant messages are scanned; the *last* message carrying a prefix wins,
  but every occurrence is collected first so conflicts are detectable.
- At least one payload occurrence is required.
- Every nonce occurrence must be identical, and every payload occurrence must be
  byte-identical after canonicalization. A conflicting pair is **terminal** — not
  retryable, not downgradable. Two different answers from one attempt is a
  compromise indicator, not a formatting slip.
- If the transcript contains **no assistant events at all**, and only then, the
  raw stdout is used as a fallback. The envelope records
  `extractionSource = 'raw-fallback'` and the result is classified as an
  environment fault with reduced authority.

Bounds, all fail-closed with distinct reason codes:

| bound | value | reason code on breach |
| --- | --- | --- |
| payload bytes | 262144 (≥ the v1 marker cap) | `payloadOverflow` (terminal) |
| scan window chars | 262144 | `payloadOverflow` (terminal) |
| field bytes | 8192 | `fieldOverflow` (terminal) |
| finding items | 12 | `findingOverflow` (terminal) |
| occurrences | 16 | `occurrenceOverflow` (terminal) |

An unterminated payload object is classified by *why* the brace matcher stopped:
out of scan window is `payloadOverflow` and terminal; out of text is
`truncatedPayload` and retryable. The distinction is the difference between "the
model wrote too much" and "we did not read all of it".

## Auth tiers

| tier | condition | may vote | in census |
| --- | --- | --- | --- |
| `authenticated` | exact nonce line, exact commit, schema and invariants valid | yes | yes |
| `evidenceOnly` | payload valid, nonce **absent** | no | yes |
| (terminal) | nonce wrong or conflicting, or any bound breached | no | no |

`evidenceOnly` is the whole point of v2. The pass is persisted, sealed, counted
in the verifier census, and available as cross-verification evidence. It cannot
vote, cannot mark a pull request reviewed, cannot become eligible, cannot be
reconciled, and cannot be delivered. The reason code is recorded on the entry so
an operator reading the census sees *why* a present reviewer did not vote.

A **wrong** nonce is not a lesser form of a missing nonce. Absent means the model
did not answer the challenge; wrong means something answered it incorrectly.
There is no downgrade path from a wrong or conflicting nonce to `evidenceOnly`,
and the parser never reinjects the expected nonce into the parsed result.

Two invariants are enforced from wrapper-derived counts, never from anything the
model asserts:

- A `recommendedVote` of `approve` alongside any `critical` or `important`
  finding is rejected.
- An empty vote placeholder is rejected.

## The wrapper envelope

`reviewer-result-envelope.v2` (schema:
`src/Agents/reviewer/schemas/reviewer.result-envelope.v2.json`,
`additionalProperties: false` throughout) is what downstream consumes. Nothing
downstream reads the model's text.

It carries the run and attempt identity (`runId`, `attemptId`, `attemptIndex`,
the exact nonce), every existing binding (project, repository, pull request,
source and target commits, change set), the requested and reported model with the
claim status between them, the prompt/input/config/script/snapshot hashes, hashes
of the final assistant message and of raw stdout and stderr, the payload hash and
object, the extraction source and occurrence counts, wrapper-derived finding and
severity counts with the invariant results, the auth tier, and process/session
identity with timings.

The envelope is sealed with an HMAC over a domain-separated canonical inventory
under the existing out-of-repo run key. At startup the key path is checked to be
outside the repository, outside the sealed-artifact output tree, and outside
every model-readable root; the reviewer refuses to start otherwise. Version
dispatch is strict — a v1 artifact is read by the v1 reader only, and a v2
artifact by the v2 reader only, with no coercion in either direction.

Every attempt writes its sealed envelope to
`<state>/logs/response-envelopes/pr<id>-cycle<n>-pass<n>-<nonce>.json`,
including `evidenceOnly` attempts. A census entry claiming "this reviewer
answered and could not vote" is only worth as much as the durable record behind
it.

## Compatibility

V1 extraction is untouched and runs first. V2 runs additionally, over the raw
stdout rather than the flattened answer so it can tell a model-emitted nonce from
one echoed back by a tool. If v1 produced a marker, v2 never demotes it. If v1
produced nothing and v2 is `authenticated`, the internal marker is rebuilt from
**wrapper state** plus the model-owned payload — never by re-serializing the
model's text and re-parsing it, which would hand the model a second bite at
fields it does not own.

The v1 marker scaffold remains in the prompt as a formatting aid. The v2 parser
does not trust wrapper-owned fields from the model under any circumstances.

## Checks

- `tools/Test-ReviewerModelResponseEnvelope.ps1` — extraction, bounds, tiers,
  sealing, cross-run substitution, key-path refusal, cross-version dispatch, the
  live CLI event-shape canary, and a real offline-adapter subprocess round trip.
- `tools/Test-ConventionSpecialist.ps1` — the rendered contract in the real
  runtime context, and the real `Invoke-ReviewerModelPass` against v2
  transcripts: nonce-absent yields `evidenceOnly`, v2-only authenticated yields a
  wrapper-rebuilt marker, and a payload bound to another commit is terminal.
- `tools/Test-ReviewerExactPath.ps1` — the decision oracle is **unchanged** by
  v2, which is the compatibility proof.
