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

| bound | value | reason code on breach | retryable |
| --- | --- | --- | --- |
| payload bytes | 262144 (≥ the v1 marker cap) | `payloadOverflow` | no |
| scan window chars, per message | 262144 total across every anchor in it | `payloadOverflow` | no |
| occurrences, per message | 16 | `payloadOverflow` | no |
| finding items | the run's own `-MaxFindings` (default 12, ceiling 25) | `payloadOverflow` on `findings` | yes |
| `filePath` | 400 chars / 1200 bytes | `payloadOverflow` on the field | yes |
| `comment` | 1200 chars / 8192 bytes | `payloadOverflow` on the field | yes |
| `summary` | 1500 chars / 6144 bytes | `payloadOverflow` on the field | yes |

Two things about that table are deliberate.

**The per-field character bounds are the v1 marker's bounds, exactly.** An
accepted v2 payload is rebuilt into a v1-shaped marker, and that marker is
re-validated — here, and again at the merged round trip that ends the cycle. If
v2 accepted content v1 refuses, the refusal would land stages later, where it is
neither retryable nor attributable to the pass that caused it, and where it costs
the *whole cycle*. So the wider contract is pinned to the narrower one, and the
rebuilt marker is re-validated against the real v1 schema before it is used.

**An overflow of a named field or item is retryable; an unnamed one is not.** A
model that writes one finding too many, or one comment too long, has made an
emission slip that a fresh attempt with a fresh nonce can fix — which is how v1
classified the same mistake. An overflow with no field is transport-level: the
payload is larger than this build will ever read, and no retry changes that.

The finding bound is the number the prompt *promised* the model. A parser
enforcing a smaller, hard-coded cap would terminally refuse a model for obeying
its instructions, so the run's effective `-MaxFindings` is passed to the
extractor, to the `findingsWithinCap` invariant, and into the contract text from
one place.

The occurrence cap is enforced *as anchors are found*, not after the whole
message has been scanned. Each anchor starts a window-bounded brace scan, so N
anchors over an L-character body is O(N·L) work on text the model chooses; stdout
is not size-capped, and this runs after the subprocess timeout has already been
satisfied. A cap checked once the expensive part is over would bound the answer
and not the work.

An unterminated payload object is classified by *why* the brace matcher stopped:
out of scan window is `payloadOverflow` and terminal; out of text is
`truncatedPayload` and retryable. The distinction is the difference between "the
model wrote too much" and "we did not read all of it".

One readable payload occurrence alongside one that is *not* readable is a
`conflictingPayload` and terminal. Dropping the unreadable one because another
happened to parse would let a transcript that says two things about one attempt
authenticate on whichever half the parser could read.

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
every model-readable root.

A state directory nested inside one of those roots is legitimate and common —
replay checkouts and harness temp trees both do it — so the answer there is not
to abort the run but to keep the key out of the root entirely: the v2 run key is
minted under a stable per-user root instead, and `run.runKeyOrigin` records
`relocated` inside the sealed bytes so an envelope can never silently claim a
stronger key provenance than it has. The root is per-user and stable rather than
per-run, because a key regenerated each run would make cross-run substitution
undetectable — every envelope would verify under whatever key happened to exist
when it was checked. Only a relocation target that is itself unsafe aborts the
run. Version dispatch is strict — a v1 artifact is read by the v1 reader only,
and a v2 artifact by the v2 reader only, with no coercion in either direction.

Every attempt writes its sealed envelope to
`<state>/logs/response-envelopes/pr<id>-cycle<n>-pass<n>-attempt<k>.json`,
including `evidenceOnly` attempts. A census entry claiming "this reviewer
answered and could not vote" is only worth as much as the durable record behind
it — so census credit requires the write to have **succeeded**. A tier held only
in the memory of a process that is about to exit is not evidence anyone can
audit, and counting it would be the same silent gap in a new place. The leaf name
carries the attempt ordinal rather than the nonce, so two identical runs produce
identically named artifacts.

## Compatibility

V1 extraction is untouched and runs first. V2 runs additionally, over the raw
stdout rather than the flattened answer so it can tell a model-emitted nonce from
one echoed back by a tool. If v1 produced nothing and v2 is `authenticated`, the
internal marker is rebuilt from **wrapper state** plus the model-owned payload —
never by re-serializing the model's text and re-parsing it, which would hand the
model a second bite at fields it does not own. The rebuilt marker carries
`sourceContract = 'v2'` and its `authTier`, so a review that came from a v2
payload is never indistinguishable from one a model emitted in v1 form.

If **both** contracts produced an answer, they must agree. The v1 marker is what
votes and posts; the v2 envelope is what is sealed and audited. If those two
describe different reviews the run would deliver one and attest to another, and
there is no safe way to pick a winner — so the attempt is refused, terminally,
because a transcript that already contains both answers cannot be improved by
asking again.

The v1 marker scaffold remains in the prompt as a formatting aid. The v2 parser
does not trust wrapper-owned fields from the model under any circumstances.

## Checks

- `tools/Test-ReviewerModelResponseEnvelope.ps1` — extraction, bounds, tiers,
  sealing, cross-run substitution, key-path refusal, cross-version dispatch, the
  live CLI event-shape canary, a real offline-adapter subprocess round trip,
  parity between the v2 bounds and the v1 marker schema lifted from the agent
  script, the promised-versus-enforced finding cap, mixed readable/unreadable
  occurrences, a bounded scan over a 4000-anchor body, and validation of the
  envelopes this code produces against the **published** JSON schema with a real
  validator.
- `tools/Test-ConventionSpecialist.ps1` — the rendered contract in the real
  runtime context, and the real `Invoke-ReviewerModelPass` against v2
  transcripts: nonce-absent yields `evidenceOnly`, v2-only authenticated yields a
  wrapper-rebuilt marker, and a payload bound to another commit is terminal.
- `tools/Test-ReviewerExactPath.ps1` — the decision oracle is **unchanged** by
  v2, which is the compatibility proof.
- The reviewer's own `-DryRun` self-checks 49 and 50 — the tier boundaries, and
  then the wrapper-side guards: a rebuilt v2 marker validates under the v1 schema
  the rest of the cycle uses, the parser enforces exactly the bound the prompt
  promised, content v1 would refuse is a retryable slip rather than a lost cycle,
  and a v1 marker that disagrees with the sealed v2 payload is detected.
