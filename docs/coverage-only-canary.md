# Coverage-only merged-master qualification

This default-off, GET-only path qualifies **exactly**
`bpm-test-class-coverage@2` and
`bpm-redundant-method-coverage@2`. It does not authorize the Owner or Named
rules, a model, a writer, or any Azure DevOps comment, vote, task, or
notification. Owner and Named are reported as `unknown` / `not-attempted`;
their zero `wouldCreate` counts are **not** zero-violation assessments.

The separate receipt (`schemaVersion: 7`,
`private-coverage-only-merged-sources`) binds each rule to its own
merge-commit/repository declaration digest, section hash, and exact policy
line hash. Its `masterCommit` records the master snapshot at receipt
creation, not a freeze of the live branch. The registry (`schemaVersion: 7`)
independently rechecks the private source-only pin against the current master
ref, bounded ancestry to the approved merge and recorded receipt snapshot,
raw Git blobs and full documents at the merge, recorded snapshot and live
master, and both declarations, as well as the current
same-bearer ConnectionData, Graph user/principal name, and Graph storage key.
An unchanged current tip needs no extra ancestry or document reads; a recorded
snapshot equal to the merge commit reuses the existing merge proof. A
non-descendant, unknown lineage, changed historical or live bytes or
declaration, or moving
master fails closed before signed state. The separately verified live master
is bound across the initial and final intake proofs and signed as
`sourceMasterCommit`, distinct from the unchanged historical receipt.
The signed intake config (`schemaVersion: 9`,
`private-coverage-only-signed-intake`) binds mode `coverage-only`, exactly
those two IDs and digests, selected head/iteration, changed lines, complete
test-project graph, and immutable two-pass inventory generation. Legacy
four-rule receipts/configs are not interchangeable. Earlier coverage-only
signed configs, including `schemaVersion: 8`, are rejected rather than
interpreted as scoped evidence or upgraded in place; the accepted source
receipt and private pin remain
unchanged. Evaluation checks the live source master against its signed intake
binding both initially and after rule evaluation; a source branch advance
with the same policy still aborts the in-flight operation as drift. Source,
identity, and selected graph/head proofs complete
**before** creating a new private intake root, lock, key, or generation.

If signed intake cannot prove a complete inventory or selected head, it still
exits with an error and creates no intake root. Its failure output contains a
sanitized `private-canary-intake-failure-diagnostic`: exact allowlisted page and
selected-head reason codes (including changed-file, graph, malformed-change,
truncation, and resource-budget failures), the failed completeness checks,
per-selected-PR eligibility (`null` if unknown), and attempted/completed GET
counts where the bound
transport can measure them. A throttle indicator stops the run without retry;
an HTTP status may be reported as a number, never with a route, header value,
account, or response body. A selected `method` is `Head`, `Changes`, or
`Discussions` only when a failed bound provider call for that selected PR was
observed; its `stage` is then `provider-call`. Otherwise both are `unknown`.
The transport's `completedGets` counts accepted bodies/JSON, not HTTP
response headers; `responseHeadersCompleted` counts headers separately when
the bound transport is available. A selected raw Item `byte-budget` can
include only the observed effective cap, bytes read so far, optional declared
length, and `headers` or `body-read` phase. A missing Content-Length does not
establish the full file size. Unknown counts remain `null`, not zero. This
diagnostic does **not** relax the completeness gate, sign a config, or provide
finding evidence. Failures from runs before this diagnostic existed cannot be
attributed to a particular page, head, or throttle retrospectively.
The coverage-only intake allows at most 512 KiB per requested source file (up
from the four-rule intake's 256 KiB). The complete, immutable changed-file
manifest binds **every** change's path, old/new commit, object ID and
body-review scope; its metadata-only records explicitly mean *not
body-reviewed by these two rules*, not that the file or whole PR was reviewed
or has zero changed lines. The separately versioned C# line proof and
evaluation content cover only changed C# candidates, including helpers,
generated sources, case-varied extensions and exact-path renames. Candidate
scope alone does not establish test-project ownership: the complete source
tree and verified project/import graph must prove all applicable test
projects, not only MSTest classes. Necessary non-C# project/import text may
still be read through that graph, not the generic changed-body diff. Unknown
membership, unsupported source bytes and ambiguous graph evidence remain
unknown, never an out-of-scope success. The 2 MiB changed-body and separate
2 MiB graph-content caps, validated blob hash and UTF-8 checks, scoped
changed-line proof, read/time limits, and complete-manifest runner recheck
remain mandatory. No C#-scoped line count represents the entire PR.
This finite engineering limit
does not imply that an unmeasured larger file qualifies: EOF beyond either
cap or a RAW body disagreeing with its declared length fails closed without
truncated evidence. The declared-length guard applies to signed BoundClient RAW Item transport;
JSON and identity GET ceilings and the legacy four-rule 256 KiB cap are unchanged.
The [ADO Item GET metadata contract](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/items/get?view=azure-devops-rest-7.1)
defaults `includeContent` to false. An absent, null, or empty `content`
property on a metadata response is not body proof; nonempty or non-string
content is rejected. A C# Item metadata encoding hint of 1252 (as well as
65001) does not decode or authorize source bytes: the separate bounded RAW
response must still pass strict UTF-8, EOF, control/LFS, and Git blob checks.
For a selected `Changes` failure, a fresh allowlisted `invalid-item` metadata
guard can identify only `old`/`new` and a fixed public predicate
(`item-shape`, `unexpected-content`, `source-media`, or `object-id`).
Without that guard the predicate remains unknown; no path, object ID,
content, encoding value, or account appears in this diagnostic.
Coverage source failures retain allowlisted receipt-drift, unproved snapshot
lineage, changed snapshot document, and merged-master metadata/content
reason codes instead of flattening
every preflight error to unknown; they do not authorize a receipt rewrite.
Selected eligibility is unknown until the whole inventory is complete; a
cleanup failure reports `canary-private-state-cleanup-failed` with the private
intake root's observed existence (`null` if it cannot be determined).

The two-pass created-time inventory tolerates an inclusive `maxTime` boundary
only when the first row exactly echoes the preceding page's consumed PR ID
and its canonical inventory fingerprint. The echo is not counted twice.
An extra lookahead preserves boundary-tie detection even when a page includes
an echo; an echo-only short page requires an empty stricter-bound terminal
probe. Unseen equal-time PRs, changed echoes, newer or unsorted rows, missing
pages, and conflicting two-pass populations remain incomplete and cannot
create signed intake state.

The PR's `lastMergeSourceCommit` and `lastMergeTargetCommit` describe heads
at the last merge attempt, not necessarily the newest iteration. In
coverage-only mode, `sourceCommit` is the newest iteration's source commit
and must match the exact live source ref. The historical iteration
`targetCommit` and `commonCommit` retain their changed-line and discussion
baseline meaning. The distinct `currentTargetCommit` records the validated
live target ref (which can have advanced since the iteration), is bound to
the declaration digest and signed selected pin, and must remain unchanged
through both intake and evaluation final-head checks. Missing, shifted,
retargeted, or ambiguous refs remain unknown before any signed state.
Per-selected-head diagnostic reasons distinguish inconsistent heads from
transport failure without exposing refs or commits.

Changed-line mapping retains the historical LCS matrix for diffs within
`maxDiffCells`. Only coverage-only heads whose trimmed matrix exceeds that
limit use a bounded exact shortest-edit-script search over the verified old
and new line tokens. On this fallback, `maxDiffCells` bounds counted search
and reconstruction operations (diagonals, token comparisons, edit steps,
and span emission) **and**, separately, the sum of retained frontier entries
and reconstruction indices/spans. These are backend-specific units, not
quadratic matrix cells; the per-Changes-call remainder is never reset.
Frontier allocations check the remaining retention budget first; the
existing deadline applies to search and reconstruction. Exhaustion is
`diff-budget` or `time-budget`, never a partial line proof. Equal-cost scripts
on repeated lines may select different valid new-side anchors than the
historical LCS tie order. Legacy four-rule mapping remains unchanged.
Selected-head `diff-budget` is a safe diagnostic, not finding evidence or
permission to skip a changed file. Its limit kind is `maxDiffCells`; the
failure diagnostic leaves the numeric limit `null` when it has not been
passed a verified count, rather than inventing one.

HTTP 200 rate-limit remaining/limit/reset budget metadata alone, even when
remaining is zero, is not a throttle signal; explicit 429/503, `Retry-After`,
or a positive server-directed rate-limit delay stops the GET-only run.

Once the parent source-only pin contract is available and an operator
explicitly provisions its ACL-private pin, selector, and key outside this
repository, the operator can use the
`tools/Initialize-PrivateCoverageCanaryInputs.ps1`,
`tools/Invoke-PrivateCoverageRuleRegistry.ps1`,
`tools/Invoke-PrivateCoverageSignedIntake.ps1`, and
`tools/Invoke-PrivateCoverageEvaluation.ps1` entry points in order. Every
entry point defaults off; `-Run` requires an explicit later operator handoff,
private external paths, and a currently signed-in approved Microsoft work
account. Never place private selectors, account aliases, principal names, or
receipts in a public file, command transcript, CI job, or PR description.
No human RSA reviewer key or independent signoff is required for the accepted
source convention. Until the separate real source-only handoff provisions its
private pin, the runnable path remains unavailable; no live source GET or
private state is authorized by this PR alone.

Evaluation uses the existing bounded complete active-PR inventory, current
non-draft/master heads, Git-bound changed lines and project graph, and
complete discussion reconciliation. Class/redundant `@2` automation markers
use a distinct `v2` namespace; a legacy `v1` marker at the same anchor is
unknown, not an `@2` no-op or an excuse to create a duplicate. Discussion,
head, identity, source or project-graph drift aborts rather than granting
writer eligibility. Findings remain candidate-only and never trigger POST.
The returned per-head/per-rule aggregates are **not** signed per-finding
delivery receipts: individual anchors and reconciliation evidence are not
persisted in a writer-consumable format. A future create-only writer remains
blocked pending its own ACL-private, signed per-finding evidence
contract and separate authorization.
