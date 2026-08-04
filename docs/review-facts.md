# Deterministic review facts

Review facts are a wrapper-owned, evidence-only layer persisted beside convention
plans. They are intended for later convention-specialist and verifier inputs. This
layer does not launch a specialist, render facts into the current generalist
prompt, create findings, post comments, or vote.

## Version 1 contract

The machine-readable schema is
`src/Agents/reviewer/facts/v1/schema.json`. Its extraction policy is the adjacent
`policy.json`. A plan is bound to the same organization, project, repository, PR,
source commit, target commit, and normalized change-set digest as convention
routing. It also records the consumer config hash, policy hash, and the hashes of
the wrapper plus both dot-sourced extraction libraries.

Every fact has:

- a stable `rf1:<sha256>` identity derived from its proposition and evidence
  coordinates, not its answer;
- one state from `true`, `false`, `unknown`, or `notApplicable`;
- a closed-vocabulary reason whenever its state is `unknown`;
- structured evidence coordinates and a content hash where bytes were observed;
- extractor, input-hash, and trust-tier provenance.

Canonical JSON uses strict UTF-8, invariant numeric conversion, ordinal key and
fact ordering, and a hard nesting limit. Invalid Unicode and oversized plans fail
closed instead of replacement-hashing or silent serialization truncation.

## Domains

| Domain | Evidence only |
|---|---|
| `metadata` | Exact Markdown headings, configured tags, checklist markers, changelog delimiters/content shape, linked-item count, draft and auto-complete fields when present |
| `cloudTest` | Changed test/project paths, exact manifest `Execution` entries, explicit framework/category/filter fields, and conservative claim intersections |
| `fanOut` | Changed JSON/XML/resource identifiers and companion surfaces established only by versioned policy or explicit same-namespace precedent |
| `threads` | Stable fingerprints, status, author class, anchor, content hash, and byte-bounded sanitized substance tagged as untrusted |
| `changes` | Pinned changed files and explicit right-side line spans; missing line transport remains `unknown` |

CloudTest never infers gating from a project or test name. A definitely-negative
gating observation requires a manifest corpus that the transport positively
proved complete; ordinary changed-file collection therefore remains `unknown`.
Fan-out never invents companion lists from a model or from an identifier name.
The default v1 policy deliberately defines no companion rules; consumers get
companion facts only after a versioned policy rule or explicit same-namespace
precedent is supplied. The current ADO change-set transport does not expose
right-side line spans to the wrapper, so production plans retain explicit
`changedLineCoverage=unknown` facts until a transport supplies exact spans.

Each domain reports `complete`, `notApplicable`, or `failed`. Transport,
truncation, malformed input, and cap failures remain explicit and do not abort
unrelated domains. The total plan is `complete`, `partial`, or `failed`.

## Persistence and invalidation

Plans are written under the reviewer state directory's `fact-plans` folder. The
JSON and HMAC signature are written through temporary files and renamed into
place. A source commit, target commit, change-set digest, config hash, policy hash,
or script-closure hash mismatch invalidates the plan.

Fact collection uses the existing dedicated, repos-only convention MCP session.
Relevant files are always requested with `versionType=Commit` and the exact PR
source commit. The PR binding and normalized change set are pinned again after
collection. A movement failure produces a failed fact plan and does not weaken or
modify current model input.
