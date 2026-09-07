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
machine-readable coverage claim: 41 offline cells are covered and five
live-only cells are explicitly structurally untestable. CI pins both the matrix
and normalization-contract bytes, so a coverage or exclusion change requires a
reviewed golden update.

`ConvertTo-ReviewerSemanticDecision.ps1` normalizes the complete exact-run
artifact graph: typed JSON, JSONL telemetry/logs, recursively embedded JSON
manifests, and rendered Markdown. Semantic comparison excludes only operational
run/session/attempt IDs, timestamps and durations, process IDs, nonces,
signatures, HMAC/key material, and their relationship-preserving derived
identities. Absolute run roots and generated artifact leaf names become stable
placeholders. Ordinary semantic fields remain. The exact-path test proves two
runs have one digest, a semantic change changes it, operational-only changes do
not, and permutation of declared set arrays does not.

Test-only JSONL telemetry is enabled only with the sealed offline adapter. It
records each actual `Process.Start`, replay serve, live provider process, and
live provider stdin write. The exact-path gate requires exactly four
role-bound `pwsh` adapter launches and rejects every other executable; it also
requires zero live provider processes and writes.

Replay is a **lower bound**. Passing replay proves behavior for the captured
read seam and deterministic adapters. Residual risk remains in live provider
responses, credentials and host policy, process environment, model service
availability, and model behavior. Those residuals require separate live and
quality evaluation; replay must not be presented as closing them.

The private bundle runner validates immutable hashes and package
executability. A private package without independent pre-authored adapter
outputs and an expected-decision oracle is not claimed as an exact-path
decision run; inventory validation must not be reported as model-quality or
decision correctness.
