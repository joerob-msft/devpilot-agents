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
receive verifier assignments. The sealed effective policy drives candidate,
cluster, input, artifact, run-count, deadline, near-exact, semantic, and existing-
thread thresholds, and replay applies those same saved values.
Policy may narrow code-defined candidate, cluster, input, artifact, verifier-run,
and phase-time ceilings but cannot widen them; the sealed effective policy records
the clamped values actually enforced.

Generalist candidates discovered by Claude Opus 5 are assigned to GPT-5.6 Sol;
Sol candidates are assigned to Opus 5. Convention candidates use the explicitly
configured generalist verifier. A sole-origin candidate cannot verify itself.
Mixed-origin clusters are still evidence-checked; corroboration is not truth.

## Verifier boundary

Each verifier receives one cluster only: assigned candidates, bounded sibling
evidence, exact source-commit hunks, cited convention quote/provenance,
deterministic facts, and sanitized existing-thread evidence. It does not receive
discovery summaries, unrelated candidates, delivery state, or write tools.

`VERIFICATION_RESULT_V1` is nonce-bound and closed to `verified`, `duplicate`,
`unsupported`, `wrongSeverity`, and `needsHuman`. Every verdict binds the exact
candidate, cluster, source snapshot, verifier model, prompt, and evidence hash.
The schema has no comment, publication, write, summary, or vote fields.
The wrapper requires the CLI to report the exact non-empty configured model for
every verifier run. Convention candidates cannot be assigned back to their
specialist discovery model even if startup validation is bypassed.

Timeout, invalid marker, stale binding, model mismatch, tool violation, missing
evidence, incomplete output, disagreement, or `needsHuman` withholds. There is no
majority vote. Verification cannot add or expand a finding or raise severity.
An absolute phase deadline and run-count cap bound aggregate verifier work; each
process receives no more than the remaining phase budget.

Convention remediation is assessed in two parts. A candidate is eligible only
when its required `changedCodeFix` is independently supported. The
`existingDebtFollowUp` part is deliberately non-atomic: it is retained only when
the verifier binds the exact sealed `rdf1:` evidence, bounded file scope, and
counts. Unsupported or ambiguous follow-up is replaced with explicit `none`
while a separately supported stop-the-bleed finding survives. Malformed
changed-code remediation, invented values, or overbroad cleanup claims withhold
the candidate.

## Eligibility and artifacts

Generalist eligibility requires an independent supported outcome and a valid
changed-file or PR-metadata anchor. Convention eligibility additionally rechecks
the exact source hash and quote, sibling requirement, deterministic fact states,
and existing-thread duplicates. A degraded specialist is recorded but cannot
remove independently verified generalist candidates.

Decision artifacts are `verification-decision-preview` manifests under
`verification-previews`. They include clusters/origins, assignments, verifier
models and prompt hashes, tool audit, decisions, withholding reasons, corrected
severity, source/fact/thread bindings, all input hashes, and final eligible
preview candidates. Input and decision artifacts derive different HMAC keys from
the reviewer master key. Delivery promotion accepts only the exact delivery
manifest key set and cannot authenticate either verification domain.

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
