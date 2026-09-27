# Bounded rule evaluation from active-PR intake

`tools/Invoke-BoundedRuleEvaluation.ps1` is a **separate, default-off,
read-only** scheduler-callable command. It does not register a task, enable
any service policy, post comments, vote, set statuses, update threads, or
send notifications. It leaves the pinned Owner and static read-only relation
cohorts and their attempts untouched. Relation has no writer or automatic
evaluation path here.

The command needs absolute external `-StateRoot`, `-IntakeConfigPath`, and
`-ConfigPath`. The intake configuration must be the exact configuration
used to create `active-pr-intake-v1/cohort.json`; the dispatcher checks its
SHA-256 binding, complete inventory, per-head declarations and changed-line
evidence, and byte-for-byte equality with the immutable generation. Intake's
two-pass ADO listing cannot provide an atomic server snapshot. Changed-line
proofs are necessary but **not rule evaluations**. A selected head without
complete line evidence is `unknown`, never `evaluated`. The intake timestamp
must be current (at most 120 minutes old in the sample), or dispatch fails
before reading ADO.

The sample [`rule-evaluation.config.json`](../samples/rule-evaluation.config.json)
has both global and per-capability switches disabled. To run an enabled
configuration, the operator supplies `DEVPILOT_RULE_EVALUATION_KEY` outside
the repository and an external `signature` of the form
`v1:hmac-sha256:<lowercase-hex>` over the UTF-8 bytes of
`ConvertTo-AgentCanonicalJson` of the configuration without `signature`.
Neither the key nor private ADO content belongs in the repository. There is
no implicit enablement through the intake setting or any existing signed
writer policy. `-Run` and a valid signature are both required. Disabled
invocations do not contact ADO or create durable dispatcher state.

At most 20 eligible master-target heads are selected per invocation, in
numeric-PR order with an atomic durable next-ID cursor. This includes old
PRs: on a stable 275-head eligible inventory, every head is offered a slot
within 14 cycles. Heads that change source, target, iteration, status, or
draft state between intake, pre-read, and post-read are unknown rather than
credited; failed reads and unavailable/over-budget evidence are separate
reasons. The cursor advances only with a committed immutable report, so a
crash before commit repeats a batch. An exclusive per-dispatcher file lock
prevents concurrent runs from sharing a cursor. Every run mints a fresh
generation under `rule-evaluation-v1/generations/`, and only observations
minted for that generation under `rule-evaluation-v1/observations/` can count
as evaluated. Previous generations never become current-head coverage,
even when the PR ID is the same. A newly changed head has to be read again.
The latest report is swapped atomically after observations and its immutable
generation are durable.

Each enabled rule receives its own new immutable
`rule-evaluation-v1/declarations/<digest>.json` with the generation,
intake declaration/line-proof digests, exact source/target/iteration,
configuration and per-rule cap. Each enabled deterministic capability
(class exclusion, redundant method
exclusion, and named `Assert.AreEqual` arguments) uses the repository's
bounded C# parsers against exact-commit source and changed spans. Its
immutable observation records the intake generation, exact source/target
commits, target ref, iteration, rule identity, rule declaration digest,
timestamp and aggregate outcome. The independent per-rule cap and global
cap both apply. Unknown
parser resolution or a cap excess cannot become a finding. Before recording
would-create counts, each enabled deterministic rule must carry a signed
`binding` with `ruleRepositoryId`, `rulePath`, `ruleCommit` (40 lowercase hex),
`ruleHash` (`v1:sha256:` of the repository-owned policy text), and
`capabilityDigest` (the repository-owned capability version). The path must be
the corresponding `src/DevPilot.OwnerCapability/Policy/<rule>.v1.txt`; the
capability digest is `v1:sha256:` of the UTF-8 policy basename followed by
`-capability-v1` (for example, `named-areequal-arguments-capability-v1`).
The dispatcher checks the local policy hash. A missing or changed binding fails
closed; the sample intentionally leaves rules disabled and has no live rule
commit to infer. The rule commit and repository ID must be the **actual pinned
rule source** used by the reviewer; signing invented values will not match
existing markers. No rule pin is inferred from the BPM PR head.

The command reuses the repository's ADO discussion normalizer and OwnerCapability
marker/body and reconciliation code per class or method group: duplicate
comments are deduplicated; an unmarked same-account comment is human, not
automation. Only a current exact marker/body/anchor is `noOp`, current exact
unmarked human coverage is `humanCovered`, and an absent relevant thread is
`wouldCreate`. Stale, moved, closed, or ambiguous discussion is `unknown`.
The immutable observation stores only digest-bound per-finding classifications,
counts (`findings`, `noOp`, `humanCovered`, `wouldCreate`, `unknown`) and a
normalized discussion digest, not source or comment bodies. These are
**read-only hypothetical outcomes**, never posting authority.
Source text and comment bodies are transient and are never written to the
cohort, observation, or normal log.

Owner remains separately default-off. Enabling Owner in the signed dispatcher
configuration requires a `binding` with `ruleRepositoryId`,
`rulePath: documentation/EngineeringProcesses/Conventions/AutomatedTests.md`,
`ruleSection: "## Claim ownership"`,
`ruleCommit: f6db83436b48f48a8521095a888d79f67823bbb2`,
`ruleHash: v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f`,
the exact positive `ruleLength`, a pinned `capabilityDigest`, and a
`model` object with the selected `id` and `digest` (`v1:sha256:` of the
UTF-8 model ID). The authoritative section bytes must be supplied separately
and checked against
that binding; a repository-local substitute or missing bytes cannot become
an Owner evaluation. An absent evaluator remains
`owner-evaluator-unavailable`. An evaluated Owner result must bind a fresh
one-entry manifest to this intake generation and rule declaration, prove a
completed no-write execution, and report every finding separately. Neither
an old pinned Owner observation nor the aggregate thread counts count as
current-head evaluation.

The repository wrapper builds the evaluator itself; it no longer accepts an
operator-supplied `-OwnerEvaluator` scriptblock. With Owner enabled in the
signed configuration, `-OwnerRuleBytesPath` identifies the exact externally
acquired EngHub section bytes (absolute path outside the repository, no
reparse point, at most 64 KiB). `-EnableOwnerLiveModel` is a separate manual
opt-in; `-OwnerModel` and `-OwnerCredentialEnvironmentName` must select the
explicit configured model and an allowed credential environment name. Missing
or mismatched bytes, provider identity, or model configuration yields an
explicit Owner unknown, not a synthetic Owner completion. The existing Owner
v2 live orchestrator provides a no-tools, isolated model process, read-only
provider, bounded lease/retry, and immutable completed record under the
private external `active-owner-evaluation-v1` state root. The dispatcher
supplies its already-budgeted discussion response to the Owner adapter;
there is no second unaccounted ADO discussion read. Source is not written in
this repository or normal output. An operator must separately acquire and
verify the pinned EngHub section and configure the live model; this PR does
not supply credentials, signed live configuration, or an active intake
generation. A private GET-only canary also remains blocked on a repository-owned
trusted provisioner for the exact pinned intake configuration, signed
dispatcher configuration and rule-source metadata, plus a bounded explicit
PR-ID selection path in the complete two-pass inventory. Do not fabricate a
cohort, hand-sign a configuration, or treat a prior pinned Owner head as
evidence for a new one.

The signed dispatcher enforces a 20-head batch, 32-finding ceiling,
configured ADO read/time budgets, and the Owner orchestrator's existing
bounded model process, evidence bytes, lease, and retry limits. It does not
expose independent signed per-head model-call, byte, time, or rate ceilings;
those would require a further orchestrator limit interface and signed
qualification configuration. This gap must be resolved before claiming
all-PR-scale live Owner evaluation.

The dispatcher repeats the active/non-draft exact-head and changed-line
checks after Owner execution, and repeats the discussion read to detect
concurrent edits. It rejects duplicated finding identities or inconsistent
per-finding counts. Owner results use the same immutable observation shape as
the other rules: a normalized discussion digest and classifications
`noOp`, `humanCovered`, `wouldCreate`, or `unknown`. These classifications
are read-only, **not** permission to create a comment. The dashboard requires
the signed EngHub declaration binding and a completed no-write Owner proof
before crediting its current-generation counters. Class, redundant, and
named-argument rules still need their own separate signed live policies; this
change does not enable them or make relation writer-eligible.

The optional dashboard `roots.ruleEvaluation` /
`files.ruleEvaluationCohort` pair points to the private dispatcher root and
its `cohort.json`, respectively. The Rules view reports current-generation scope, classified finding counts,
evaluated, pending, skipped, unknown, and errors separately from
the pinned canary history. Configuration of this optional feed does not
deploy the dispatcher.
