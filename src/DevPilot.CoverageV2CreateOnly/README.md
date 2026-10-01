# Coverage @2 create-only boundary

This isolated PowerShell module exports no commands and is not wired into a
scheduler or provider. `Invoke-CoverageV2CreateOnly` is default-off; even an
explicit `enabled = $true`, `mode = coverage-v2-create-only` configuration
**cannot authorize a write**. Its offline decision helper is diagnostic, not an
authorization result. It only accepts a `coverage-v2-unsigned-finding-candidate`
shape, and rejects schema-9 read-only results, aggregate `wouldCreate` counts,
and claims of `writerEligible`; caller-supplied `signedVerified` cannot authorize
anything. No network operation or file mutation is implemented. The candidate
contains a full bound finding and request, head/source/manifest/graph/principal/
discussion receipt fields and digest slots, and a complete two-pass run cohort.
The diagnostic
recomputes the exact @2 marker and body with `DevPilot.OwnerCapability` and
uses `DevPilot.AgentHarness` canonical digests. These **unsigned caller data**
are not authenticated source receipts, a current-generation proof, or a
signed per-finding selection.
The diagnostic requires a complete cross-PR run-history scope and counts
same-rule/same-run reservations across **all** selected PRs, while the
five-per-rule/PR history remains separate. A caller-supplied completeness
claim is never posting authority.
The offline path guard recognizes `.cs` and `.CS` without normalizing Git path
case: a case-variant discussion path is ambiguous, never HUMAN-covered.
Case-variant or malformed DevPilot automation markers likewise block the
diagnostic `wouldCreate` outcome.
The diagnostic classifies a HUMAN thread as covered only for the shared
Owner @2 affirmative comment predicate, a current context, and a matched
reviewer identity; negated, questioning, incomplete, or stale advice is
ambiguous, not proof of coverage.

PR191 `Get-RuleEvaluation` returns per-finding digest, classification, and
reason; `PrivateCanaryRunner` discards those outcomes and persists only an
aggregate with `writerEligible = false`. Neither is signed individual finding
authority. The @2 discussion reconciliation helper in
`DevPilot.OwnerCapability` can be reused to verify a future fresh read;
the existing Owner @1 provider cannot be wired here because it has a distinct
credential and update operations.
The existing service authorization key and aggregate signed intents are not
per-finding approval. Before any integration, an independently trusted signer
must issue a fresh, domain-separated intent for **one** bound @2 finding,
including the rule declaration, exact recomputed v2 marker and body, approved
source bytes, PR iteration/current source and target, reviewer GUID and
descriptor, same bearer session, and expiry. A verifier must authenticate the
envelope and all those fields rather than accept a caller-supplied `verified`
flag. The approved merged source and actual finding must be available, not
only a summary digest.

A provider integration also needs a same-bearer identity and current
head/source GET proof, a complete authoritative discussion GET/readback with
the exact HUMAN GUID and descriptor, and an ACL-private, serialized historical
per-PR ledger with separate immutable `(ruleId, PR)` buckets.
Reserve each finding before POST, count reservations and uncertain attempts
against two per rule/run and five **per rule/PR** across all heads, configurations,
and restarts, and never retry an ambiguous POST. Run fresh same-bearer HEAD,
source, identity, and reconciliation checks immediately before **each**
attempt; an earlier two-pass cohort is not sufficient. Limit the provider to
GET and POST `CreateThread`; never
expose votes, comment updates, tasks, notifications, models, Owner, or Named
capabilities. Keep the module unexported and disabled until all contracts are
implemented and independently verified.

`DevPilot.CoverageV2Ledger.psm1` is a **proof-neutral offline primitive**, not
the missing production ledger. It exports nothing. Its trusted entry refuses
before touching a real root because no verified signed per-finding authority
exists. Only a dedicated fictional, test-owned repository-relative fixture
route can exercise the HMAC-chained, private-ACL-checked CreateNew journal and
one exclusive **global** lock. Every operation scans a bounded set of
HMAC-verified rule/PR buckets under that lock; unknown, empty, inaccessible,
or corrupt buckets refuse the entire operation. It records reservation, one
attempt, and one terminal
readback (`confirmed`, `missing`, or `ambiguous`); every reservation consumes
the two-per-rule/run budget **across PRs**, and the five-per-rule/PR budget
across rereads, independent of head or configuration. A busy or stale global
lock, malformed event, broken chain, or uncertain attempt blocks retry without
an automatic recovery path.
Fixture root and child directories must already have private permissions and
link-free ancestry before any lock or journal is created. New test-owned files
are verified private before writing their contents.

Production integration still requires a trusted root outside the repository,
an independently verified signer and identity, serialized history whose
deletion cannot silently reset a bucket, and authoritative same-bearer
readback. The fixture HMAC key and caller-provided history are never posting
authority; the fixture ledger cannot be promoted by setting a flag.
