# Gate 0/1 exact-path orchestration

These checks establish **orchestration correctness, not model quality**. They
exercise process deadlines and drains, result-marker parsing and binding,
role routing, and deterministic semantic comparison. They do not establish
precision, recall, usefulness, or safety of a live model's review.

`tools/Invoke-ReviewerExternalBundle.ps1 -Root <private-root>` validates the
mandatory artifacts by SHA-256 and enumerates exactly 20 recommended
fixtures. The plan/index SHA binding is resolved to the corrected ownership
overlay payload, whose bytes are independently hashed before parsing. Missing
or ambiguous overlay evidence and blocked or non-executable fixture records
fail closed. The tool never copies private content into this repository,
refuses a bundle root inside the working tree, and does not print fixture
content.

`tools/testdata/reviewer-structural-coverage-matrix.v1.json` is the
machine-readable coverage claim. `ConvertTo-ReviewerSemanticDecision.ps1`
implements its normalization contract. Semantic comparison excludes run IDs,
timestamps, nonces, signatures, and HMAC key material; these prove run
identity or artifact integrity, not a review decision.

Replay is a **lower bound**. Passing replay proves behavior for the captured
read seam and deterministic adapters. Residual risk remains in live provider
responses, credentials and host policy, process environment, model service
availability, and model behavior. Those residuals require separate live and
quality evaluation; replay must not be presented as closing them.
