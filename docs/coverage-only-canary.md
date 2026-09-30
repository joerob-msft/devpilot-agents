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
line hash. The registry (`schemaVersion: 6`) independently rechecks the
private source-only pin against the current master ref, ancestry, raw
Git blob, full document, and both declarations, as well as the current
same-bearer ConnectionData, Graph user/principal name, and Graph storage key.
The signed intake config (`schemaVersion: 6`,
`private-coverage-only-signed-intake`) binds mode `coverage-only`, exactly
those two IDs and digests, selected head/iteration, changed lines, complete
test-project graph, and immutable two-pass inventory generation. Legacy
four-rule receipts/configs are not interchangeable. Source, identity, and
selected graph/head proofs complete **before** creating a new private intake
root, lock, key, or generation.

If signed intake cannot prove a complete inventory or selected head, it still
exits with an error and creates no intake root. Its failure output contains a
sanitized `private-canary-intake-failure-diagnostic`: allowlisted page and
head reason codes, the failed completeness checks, per-selected-PR eligibility
(`null` if unknown), and attempted/completed GET counts where the bound
transport can measure them. A throttle indicator stops the run without retry;
an HTTP status may be reported as a number, never with a route, header value,
account, or response body. Unknown counts remain `null`, not zero. This
diagnostic does **not** relax the completeness gate, sign a config, or provide
finding evidence. Failures from runs before this diagnostic existed cannot be
attributed to a particular page, head, or throttle retrospectively.
Selected eligibility is unknown until the whole inventory is complete; a
cleanup failure reports `canary-private-state-cleanup-failed` with the private
intake root's observed existence (`null` if it cannot be determined).

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
