# Cross-verification previews

Cross-verification is an optional wrapper-owned layer over the two independent
generalist discovery passes and convention-specialist discovery. It is disabled
unless `-EnableVerificationPreview` or `review.verification.enabled` is set.
It never changes the generalist union, summary, delivery comments, state, or vote.

## Inputs and replay

The wrapper seals a `verification-input-preview` artifact containing:

- each raw generalist marker, model ID, and SHA-256;
- the raw convention-specialist manifest, candidates, status, and artifact hash;
- immutable PR/source/target/change-set, config, script, prompt, policy, schema,
  convention-plan, and fact-plan bindings;
- normalized version-1 candidates and deterministic candidate hashes;
- sanitized thread facts, exact source-commit evidence hunks, convention sources,
  cluster membership, origins, and verifier assignments.

Replay reads this artifact and saved verifier records. It reconstructs cluster
IDs, ordering, eligibility, corrected severities, and withholding decisions
without rerunning discovery. Array shape is preserved for empty, singleton, and
multiple values; canonical JSON uses strict UTF-8, ordinal ordering, and invariant
numeric formatting.

## Clustering and assignments

Candidate clustering is wrapper-deterministic and advisory. Exact and near-exact
findings cluster by normalized claim and anchor. A bounded semantic pass groups
paraphrases and cross-file candidates only when issue class and behavior tokens
substantially overlap. Clusters use complete-link cohesion: every member must
match every other member, so a chain of merely adjacent similarities cannot join
unrelated same-family findings. Cross-file matching requires stronger shared
root-cause evidence than same-file matching. File/line overlap alone never merges
candidates. Originals remain in the sealed input, and each cluster ID is the hash
of its ordered member hashes.

Candidate and cluster caps isolate rather than erase work. Candidates beyond the
normalization cap and every member of an oversized semantic cluster are listed
individually as `candidateLimit` or `clusterLimit`; unrelated ready clusters still
receive verifier assignments. Original blind findings and specialist findings are
admitted before optional wrapper-enriched variants, so bounding can never retain an
enrichment after withholding its origin. The sealed effective policy drives candidate,
cluster, input, artifact, run-count, deadline, near-exact, semantic, and existing-
thread thresholds, and replay applies those same saved values.
Policy may narrow code-defined candidate, cluster, input, artifact, verifier-run,
and phase-time ceilings but cannot widen them; the sealed effective policy records
the clamped values actually enforced. Before any verifier process launches, the
wrapper derives the required assignment budget as twice the bounded union size and
requires exactly one assignment from each generalist for every candidate. A policy
budget below `2N` fails the phase before launch rather than partially verifying the
union. The code-defined hard cap remains an absolute ceiling.

Blind discovery is three-way and isolated: GPT generalist, Opus generalist, and
the convention specialist do not receive one another's findings. After all
three blind passes finish, the wrapper forms the exact candidate union without
requiring discovery overlap. Every GPT-only, Opus-only, and specialist-only
candidate then receives two fresh cross-checks: one from GPT and one from Opus.
If any configured blind pass is missing or degraded, cross-verification fails before
launch and exposes no eligible candidate.
The specialist never cross-checks. A candidate is semantically accepted only
when both cross-checks bind supplied evidence and concur on the exact outcome;
blind overlap, first/latest wording, majority, and specialist concurrence are
not substitutes. The specialist discovery model must differ from both
generalist cross-check models. Mixed-origin clusters remain advisory for
deduplication.

Before cross-checking, the wrapper may add an enriched variant of a blind generalist finding with
convention evidence, but only when the normalized path matches a selected pack,
the exact line is inside one sealed right-hand `RawSpan`, and the referenced
authoritative section is present in the sealed source bytes. The enrichment records
wrapper provenance, binds the exact rule source/hash/section, and supplies a
structured `changedCodeFix` against the truthful `cf<n>` anchor. Its convention key
is an existing sealed source identity; it never invents a localization resource key.
The original blind finding always remains in the union, so speculative convention
routing cannot replace or suppress it. If the bindings are unavailable, ambiguous,
or not deterministically relevant to the finding text, no enriched variant is added
and the original proceeds under the normal evidence requirements.

## Verifier boundary

Each fresh cross-check invocation receives one cluster only: assigned candidates, bounded sibling
evidence, exact source-commit hunks (preferentially reconstructed from already
sealed source slices), cited convention quote/provenance,
deterministic facts, and sanitized existing-thread evidence. It does not receive
discovery summaries, unrelated candidates, delivery state, or write tools.

`VERIFICATION_RESULT_V1` is nonce-bound and closed to `verified`, `duplicate`,
`unsupported`, `wrongSeverity`, and `needsHuman`. Every verdict binds the exact
candidate, cluster, source snapshot, verifier model, prompt, and evidence hash.
The schema has no comment, publication, write, summary, or vote fields.
The wrapper requires the CLI to report the exact non-empty configured model for
every cross-check run. The sealed assignment set must contain exactly one GPT
and one Opus cross-check per candidate. Convention candidates cannot be assigned
to their specialist discovery model even if startup validation is bypassed.

Timeout, invalid marker, stale binding, model mismatch, tool violation, missing
evidence, incomplete output, disagreement, or `needsHuman` withholds. There is no
majority vote. Verification cannot add or expand a finding or raise severity.

## Phase budget

An absolute phase deadline and assignment-count cap bound aggregate verifier work.
One function, `Get-ReviewerVerificationPhaseBudgetPlan`, is the only source of both
the admission decision and the per-invocation timeout, so the number a run is
launched with is by construction the number the preflight reserved for it.

What is budgeted is **assignments, not invocations**. The requirement is that every
candidate is cross-checked once by GPT and once by Opus, so the unit the phase must
be able to afford is the `2N` assignment set - the same unit the acceptance
boundaries are stated in. Budgeting the grouped invocation count instead was a
defect: grouping is an optimisation, and an optimisation that shrinks the
reservation makes the reservation a promise about the implementation rather than
about the work.

The plan divides the phase rather than reserving a ceiling per run:

```
remaining     = max(0, min(policy phase seconds, 3600) - elapsed - reservedOverhead)
share         = floor(remaining / assignments)
perAssignment = min(configured run timeout, share)
perInvocation = min(configured run timeout, floor(remaining / invocations))
admit         <=> assignments <= effective max assignments AND perAssignment >= minAssignment
minAssignment = min(configured run timeout, 300)
```

Admission is decided on `share`, the conservative per-*assignment* slice. Time is
handed out per *invocation*, and invocations are never more numerous than the
assignments they cover, so `invocations x perInvocation <= remaining` holds however
the assignments are grouped. That is what makes the accounting safe under batching
without having to launch one process per assignment. An invocation count above the
assignment count is a contradiction and throws.

Reserving the configured per-run *ceiling* for every planned run was the earlier
behaviour, and it refused ordinary work: at the shipped 900 s run timeout, a
3-candidate pull request needs 6 assignments and a 5-candidate one needs 10,
demanding 5400 s or 9000 s against a 3600 s phase - so zero verifiers launched, even
though each of those runs finishes in far less. That treated a ceiling as if it were
a cost.

The 300 s `minAssignment` floor is measured, not guessed. Across the sealed replay
runs kept as qualification evidence, a bounded single-model cross-verifier CLI
phase completed in **136-295 wall-clock seconds**; 300 s sits just above the
slowest observation. It is a floor on what may be *handed* to a run, not a
prediction of what a run will take: below it a launch is not a shorter review, it
is a review that ends in `timeout` and produces nothing. The floor never exceeds
what the operator configured, because a deployment that declares short verifier
runs is describing its own runs.

`reservedOverhead` is 120 s and exists because the hard wall-clock bound is a bound
on the **phase**, not on the launches inside it. Clustering, fresh nonce binding,
prompt construction, artifact validation and postprocessing all consume phase time
that no per-run timeout covers, so the budget takes that reservation off the top
before dividing anything.

The plan also returns `phaseDeadlineSeconds`, and that deadline is **enforced, not
logged**. After the verifier invocations and before any of the post-launch tail,
`Get-ReviewerVerificationPhaseDeadlineState` decides whether the tail may still be
started: it may not once fewer than 15 s remain, because beginning work the
deadline cannot cover is how a hard bound decays into an advisory one. `overrun`
(the deadline has passed) and `exhausted` (it has not, but too little is left) are
reported distinctly and stop the phase identically.

Stopping means stopping. Every verifier run is degraded under the `phaseDeadline`
reason, the **live** fresh binding is skipped rather than attempted on borrowed
time, the pass is reported `degraded`, and
`Limit-ReviewerVerificationToPhaseDeadline` moves anything still standing out of
`eligible` and into `withheld` under that same reason. Nothing eligible can be
previewed from a phase that ran past its bound, and the preview says plainly why
it is empty instead of silently showing less. Because admission is computed once,
before any launch, none of this can produce a partially launched set - the launches
either all happened or none did, and the deadline only governs what may be
published afterwards.

The fresh binding is the one part of the tail that can run for an unbounded time,
so checking the deadline before it is not enough: the call itself could breach the
bound and the phase would still publish. `Get-ReviewerVerificationFreshBindingBudget`
decides whether it may start at all, and under what transport timeout. The worst
case it bounds is the per-request MCP timeout times the six requests the pinned
change-set read can make (target commit, first change set, PR re-read, second
change set, target commit again, plus session setup), plus the session cleanup's
seven-second termination bound. That worst case must fit in what remains *above*
the postprocessing floor. The configured transport timeout
is lowered to fit rather than trusted to be short enough; below a 5 s per-request
floor the binding is not started at all and the phase fails closed by degrading its
runs, exactly as an overrun would. The deadline is then re-evaluated immediately
**after** the binding and before anything is published, so a phase that crossed the
line while re-binding still withholds every finding.

With the shipped defaults (3600 s phase, 900 s configured run timeout, 120 s
reserved overhead) the phase admits up to **11 assignments**; 6 assignments get
580 s each and 10 get 348 s each. Twelve cannot give every assignment a usable
slice and is refused before any launch.

Everything else about the bound is unchanged. The 3600 s phase and 128-run hard
caps stay absolute and no policy can widen them; admission is still computed once
for the whole `2N` set and is still all-or-none, so the group loop never re-checks
the phase clock mid-loop and a refusal launches nothing at all. Each process
receives no more than its reserved share, so even if every admitted run consumes
its entire slice the phase still ends inside the hard wall-clock bound. Fresh
per-run nonces, exact assignment accounting, the GPT-and-Opus concurrence
requirement, and the specialist's exclusion from cross-checking are all
untouched.

Convention-bound remediation is assessed in two parts regardless of whether the
blind origin was GPT, Opus, or the specialist. A candidate is eligible only
when its required `changedCodeFix` is independently supported. The
`existingDebtFollowUp` part is deliberately non-atomic: it is retained only when
the verifier binds the exact sealed `rdf1:` evidence, bounded file scope, and
counts. Unsupported or ambiguous follow-up is replaced with explicit `none`
while a separately supported stop-the-bleed finding survives. Malformed
changed-code remediation, invented values, or overbroad cleanup claims withhold
the candidate. The wrapper supplies dedicated evidence options for both parts,
including precomputed canonical digests and exact fact subsets; verifier models
copy these values and never compute hashes. Deterministic model input contains
the bounded union of candidate facts and changed-code remediation facts.
Malformed, duplicate, invented, or individually oversized subsets withhold only
their candidate. If otherwise-valid candidates in one semantic cluster would
exceed the per-run fact or byte bound, deterministic cluster admission withholds
only the candidate that crosses the bound; unrelated candidates and clusters
continue without degrading the verification pass.

## Eligibility and artifacts

Generalist eligibility requires an independent supported outcome and a valid
changed-file or PR-metadata anchor. Convention eligibility additionally rechecks
the exact source hash and quote, sibling requirement, deterministic fact states,
and existing-thread duplicates.

Decision artifacts are `verification-decision-preview` manifests under
`verification-previews`. They include clusters/origins, assignments, verifier
models and prompt hashes, tool audit, decisions, withholding reasons, corrected
severity, source/fact/thread bindings, all input hashes, and final eligible
preview candidates. Input and decision artifacts derive different HMAC keys from
the reviewer master key. Delivery promotion accepts only the exact delivery
manifest key set and cannot authenticate either verification domain.

For repeated sealed executions, each decision artifact also embeds a
reconciliation manifest whose candidate list is every convention-bound candidate
accepted by both GPT and Opus, including wrapper-enriched
generalist origins. Corrected severity and the removal of unsupported existing-debt
follow-up are applied before sealing this subset. Reconciliation never reads
rejected or superseded raw semantics from that artifact.
Exact `cf<n>:line` violations are reconciled as first-class anchors alongside the
separate lexical construct partition; stable line targets never become invented
constructs and count as weighed evidence for the rule.

When the convention specialist degraded there is no manifest to embed - its
discovery is not trusted - so `reconciliationManifest` is `null`. In offline
replay the decision artifact also carries the same `replay` identity block the
specialist preview carries (snapshot, manifest digest, nonce, never promotable),
so such a run can still be bound to the recording it replayed and reconciled as
an empty run. See "A run that produced nothing" in `docs/replay-snapshots.md`
for the exact conditions under which that is accepted.

## Layer 6: delivery gates

An optional, separate, fail-closed layer reads this preview's sealed eligible
candidates to decide - never to change - what may reach a PR as an unattended
comment, suggestion, or approval vote. It is off unless an out-of-repo policy
file, a matching CLI switch, and a verified qualification artifact all agree;
a repository's own config can only disable it, never enable it. It uses its
own HMAC domain, so a gate artifact can never be read back as, or promoted
as, a raw delivery or verification artifact, and vice versa. See
[Delivery gates](delivery-gates.md).

Cross-verification never authorizes a raw write on its own: an independent
two-pass union stays a code-defined `PreviewOnly` delivery authorization
permanently, whether or not this layer is enabled. The gate is the sole,
code-defined path by which a `VerifiedMultiPass` authorization is ever minted,
and that grant authorizes only the gate's own comment/suggestion/approval/
`-PromoteVerifiedPreview` writes - never the raw two-pass delivery or raw
`-PromotePreview` path.
