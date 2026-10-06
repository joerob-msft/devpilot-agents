# Production rule delivery

- Done means an additional accepted rule is enabled through v2 on current PRs, with a verified real evaluated outcome and correct delivery/readback when a finding is warranted. Offline, static, or Fake passes and UNKNOWN/skipped outcomes are intermediate evidence, not deployment success.
- Reuse the existing intake, evaluation, source authority, and delivery paths. Do not add a harness, signer, key, launcher layer, or permission ceremony just to add a rule; justify supporting changes by the smallest concrete production blocker.
- Deliver the smallest independently accepted rule end to end first. Do not hold independent rules behind full-repository diagnostics, filter away relevant ownership, change agreed rule semantics or source acceptance, or repurpose two-rule coverage receipts.
- For each exact blocker, make the minimal fix or request an explicit policy decision; do not spin indefinitely on harness work. Never silently increase limits, weaken ownership proofs, or infer success from UNKNOWN. Preserve existing quotas, history, idempotency, and Owner behavior.
- Report the rules actually live, actual current-PR evidence, and the remaining concrete blocker. Stop unrelated work and new layers; measure progress by production outcomes, not fixture counts.
