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
approved signed private pin against the current master ref, ancestry, raw
Git blob, full document, and both declarations, as well as the current
same-bearer ConnectionData, Graph user/principal name, and Graph storage key.
The signed intake config (`schemaVersion: 6`,
`private-coverage-only-signed-intake`) binds mode `coverage-only`, exactly
those two IDs and digests, selected head/iteration, changed lines, complete
test-project graph, and immutable two-pass inventory generation. Legacy
four-rule receipts/configs are not interchangeable. Source, identity, and
selected graph/head proofs complete **before** creating a new private intake
root, lock, key, or generation.

After a separate review publishes the approval anchors and an operator
installs the ACL-private pin, selector, and key outside this repository,
the operator can use the
`tools/Initialize-PrivateCoverageCanaryInputs.ps1`,
`tools/Invoke-PrivateCoverageRuleRegistry.ps1`,
`tools/Invoke-PrivateCoverageSignedIntake.ps1`, and
`tools/Invoke-PrivateCoverageEvaluation.ps1` entry points in order. Every
entry point defaults off; `-Run` requires an explicit later operator handoff,
private external paths, and a currently signed-in approved Microsoft work
account. Never place private selectors, account aliases, principal names, or
receipts in a public file, command transcript, CI job, or PR description.
The public reviewed-pin signature and reviewer key anchors are intentionally
unset: without a separate reviewed activation and private approval, the
runnable path stops before source GET or state creation.

Evaluation uses the existing bounded complete active-PR inventory, current
non-draft/master heads, Git-bound changed lines and project graph, and
complete discussion reconciliation. Class/redundant `@2` automation markers
use a distinct `v2` namespace; a legacy `v1` marker at the same anchor is
unknown, not an `@2` no-op or an excuse to create a duplicate. Discussion,
head, identity, source or project-graph drift aborts rather than granting
writer eligibility. Findings remain candidate-only and never trigger POST.
