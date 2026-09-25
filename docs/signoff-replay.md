# Sign-off confidence replay (preview)

This standalone, read-only experiment is not an agent role or an approval
authorization. It does not use reviewer/handler state, provider tools, votes,
comments, Golden, or the dashboard. No release/install pin change is required.
Consumers explicitly select a local toolkit checkout.

## Frozen v1 consumer contract

The authoritative schemas are `src\DevPilot.SignoffConfidence\schemas\bundle.schema.json`,
`assessment.schema.json`, and `result.schema.json`. `samples\signoff\complete.bundle.json` is a public,
synthetic example. All JSON is strict: unknown/duplicate keys, nonfinite numbers,
unknown enums/references, out-of-range probabilities, and future evidence fail.

Each input file is one case. A batch directory contains only `*.bundle.json`.
`caseId` is a safe unique identifier; `familyId` groups snapshots from the same
source PR (not different PR IDs for every iteration). `cohort` separates NATURAL,
HISTORICAL, and SYNTHETIC. Provenance binds repository, PR, source/target commits
and refs, iteration (null when unavailable), cutoff, and export time.

Reconstruction is EXACT, CURRENT_SNAPSHOT, or UNSUPPORTED with a reason. Only
EXACT historical cases are historical-benchmark eligible; unsupported historical
reconstruction remains visibly exploratory and cannot produce final APPROVE.
The four completeness categories CODE, INTENT, POLICY, VALIDATION must each
occur exactly once; COMPLETE requires supporting evidence references. There is
no model-granted exemption from a missing category. Arbitrary versioned approved
guidance goes in `guidance`. Evidence content is untrusted data, never instructions.
CODE_CHECK FAIL means a proven, snapshot-bound code failure, not a missing build,
infrastructure outage, canceled job, or tests-skipped build. Use UNKNOWN for those.
Evidence timestamps must not exceed cutoff and must match both snapshot commits.

`label` is null or a separately held evaluation target. It is stripped before
constructing model input; never put votes, merge outcomes, target labels, or
post-cutoff facts in evidence/guidance. Exporters own accurate reconstruction and
semantic redaction: a schema cannot detect concealed outcomes inside prose.

The completeness flags are attestations by the exporter/operator, not proof the
model has all relevant code. A manual enrichment must capture and review the
missing full code/intent at the same immutable source/target revisions and
cutoff, cite new evidence, update completeness truthfully, and create a new
output run. Do not flip flags alone. Current-snapshot enrichment does not make
unknown historical policy EXACT.

## CLI contract

```powershell
# Explicit Python 3.11+ interpreter; install/provision separately, never in a run.
.\tools\Invoke-SignoffReplay.ps1 -Action ValidateBundle -InputPath C:\pilot\cases
.\tools\Invoke-SignoffReplay.ps1 -Action Run -Mode Offline `
  -InputPath C:\pilot\cases -FixturePath C:\pilot\responses.json `
  -OutputRoot C:\pilot\results -Model fixture-v1 -MaxCases 25
# Resume only an exact input/pipeline/model/provider match:
.\tools\Invoke-SignoffReplay.ps1 -Action Run -Mode Offline `
  -InputPath C:\pilot\cases -FixturePath C:\pilot\responses.json `
  -OutputRoot C:\pilot\results -Model fixture-v1 -Resume
```

Python equivalent: `python src\DevPilot.SignoffConfidence\signoff_replay.py
validate-bundle --input PATH` or `run --mode offline --input PATH --fixtures PATH
--output-root PATH --model fixture-v1`. The offline provider is explicit, never a
live-error fallback. Fixture responses have shape
`{"schemaVersion":1,"cases":{"CASE_ID":[ASSESSMENT,ASSESSMENT]}}`; each assessment
follows the schema and has exactly the intent/correctness/validation questions.
Fixture mode accepts SYNTHETIC/FIXTURE cases only.

Run parameters: MaxCases=25 (1..25), DeadlineSeconds=60 (1..600) per assessment,
MaxAttempts=1 (1..2), concurrency fixed at one, two independent assessments per
model-positive case. Budget is the hard call ceiling of 2 * MaxAttempts per case;
unknown monetary/provider usage is null, never fabricated zero. No paid usage
claim is inferred from this call ceiling.

For model-based final APPROVE, both validated responses must say APPROVE, all
three questions must be YES, risk must be LOW, no blockers can remain, and both
direct estimates must be at least **0.9**. This code-owned MVP support floor is
an **uncalibrated heuristic**, not evidence of 90% accuracy or an auto-approval
threshold. The prompt does not disclose or ask models to reach it. Lower raw
estimates remain unchanged in each run and cause LOW_MODEL_SUPPORT abstention.
The displayed readiness probability is the primary assessor's direct estimate;
the challenger gates the recommendation. Estimates are never multiplied,
averaged into a claimed joint probability, calibrated, or normalized.

`-Exploratory` / `--exploratory` permits two model-only diagnostics when CODE and
INTENT are complete and guidance is approved, even if policy/history is missing.
The final result still abstains and its probability stays null; diagnostics live
under `modelOnlyDiagnostic` and complete raw validated responses under `runs`.
Partial code or intent still prevents inference. Deterministic CODE_CHECK FAIL
short-circuits to REQUEST_CHANGES; unavailable infrastructure never does.

OutputRoot must be outside the toolkit and any Git working tree. An exclusive
lock prevents concurrent writers. `manifest.json`, `results.jsonl`, per-case
`cases\CASE_ID.json`, `metrics.json`, and `summary.md` are deterministic persisted
artifacts. A different input, fixture, model, deadline, attempt setting, engine or
schema fingerprint cannot resume the same root. Exit 0 means valid artifacts
were produced (including abstentions), not approval/readiness. Exit 2 means
invalid input/configuration; exit 3 means a live capability/auth/runtime no-go.
Exit 130 means cancellation (`-CancelFile PATH` signals when that file exists);
exit 124 means the containing process deadline terminated the process tree.
Successful assessment attempts are locally validated before persistence.
Per-case files use `{"digest":"...","result":RESULT}`; JSONL contains bare RESULT.
Digests detect accidental corruption, not malicious local edits or authenticity.
Use operator-restricted input/output directories; outputs can contain private
review reasons. No raw model response, SDK traceback or credential is logged.

On a crash/cancellation, completed per-case files survive; aggregate artifacts
are published only after all cases finish and are rebuilt on exact resume.
Resume never retries a persisted failed case or silently changes the pipeline.
Use a new output directory for a new model, changed evidence, or renewed attempt.
The JSON representations/ordering and summaries are deterministic given the
validated responses; live inference itself is not deterministic.

Metrics report separate NATURAL/HISTORICAL/SYNTHETIC confusion matrices with
all three output classes, total/eligible/ineligible/labeled/unlabeled/abstention
denominators and PR-family counts. Historical-ineligible cases are excluded only
from that benchmark's confusion matrix, with an explicit ineligible count.
There is no accuracy claim from positives, fixtures, absent labels, or agreement.
Snapshots within one family are correlated. Calibration fitting, Brier/log loss,
plots, independent outcome adjudication and deployment claims are deferred.

## Provisioning and live SDK gate

Python 3.11+ and PowerShell 7.4+ are explicit prerequisites. Provision an isolated
environment **before** evaluation. Offline mode requires only the first manifest;
it does not import the SDK or start/network a runtime.

```powershell
python -m venv C:\pilot\venv
C:\pilot\venv\Scripts\python.exe -m pip install -r .\src\DevPilot.SignoffConfidence\requirements.txt
.\tools\Invoke-SignoffReplay.ps1 -Action Run -Mode Offline `
  -PythonPath C:\pilot\venv\Scripts\python.exe `
  -InputPath .\samples\signoff\complete.bundle.json `
  -FixturePath .\samples\signoff\responses.json -Model fixture-v1 `
  -OutputRoot C:\pilot\sample-result

# Optional live provisioning: exact SDK/dependency versions, no mutable-main API.
C:\pilot\venv\Scripts\python.exe -m pip install -r .\src\DevPilot.SignoffConfidence\requirements-live.txt
$env:COPILOT_CLI_EXTRACT_DIR = 'C:\pilot\runtime-1.0.85'
C:\pilot\venv\Scripts\python.exe -m copilot download-runtime
# Supply DEVPILOT_SIGNOFF_GITHUB_TOKEN through your approved secret mechanism.
# It must carry Copilot model entitlement. No credential is accepted on the CLI.
.\tools\Invoke-SignoffReplay.ps1 -Action Run -Mode Live `
  -PythonPath C:\pilot\venv\Scripts\python.exe `
  -RuntimePath C:\pilot\runtime-1.0.85\prebuilds\win32-x64\copilot-runtime.exe `
  -InputPath C:\pilot\cases -OutputRoot C:\pilot\live-result `
  -Model gpt-5.4-mini -MaxCases 1 -MaxAttempts 1 -DeadlineSeconds 60 -MaxAiCredits 30
```

The released `github-copilot-sdk==1.0.14` wheel pins runtime **1.0.85**; the SDK's
explicit download command verifies upstream release SHA256SUMS. Runtime assets
are fingerprinted and the running runtime version is checked. Evaluation passes
an explicit binary and disables automatic downloads. SDK/dependency versions are
pinned in the manifests; no first-use package install or authentication fallback.

Live uses the Windows wrapper's Job Object descendant containment; portable
offline Python does not imply supported uncontained live execution. Each
assessment/retry uses a fresh temporary non-repository directory, runtime,
empty-mode SDK client, and session. The runtime receives only basic Windows
environment paths plus isolated home/config/temp directories and the explicit
token through the SDK. Existing session variables, user tools, MCP config,
provider configuration, extensions, and repository instructions are not inherited.

The SDK config explicitly disables builtins (empty complete allowlist), custom
tools/agents, MCP, plugins, skills, file hooks, instruction/config discovery,
memory, session store, git operations, scheduling, remote sessions and tool
search. All permission requests are rejected. Known built-in GitHub MCP names
are explicitly disabled before startup; readback must show them `disabled`.
Before and after every send, the initialized tool metadata must be exactly `[]`
(not null), plugin/extension catalogs empty, MCP servers absent or explicitly
disabled known builtins, and selected model unchanged. Unexpected tools or
session errors invalidate the assessment. These are released, partly
experimental APIs; a missing API/capability is a no-go, never permission to
weaken isolation or use CLI text. This is a no-model-tools boundary, not a
general OS sandbox: the trusted SDK runtime still needs its inference network.

Explicit model discovery must find the requested ID; auto/default/fallback are
forbidden. Each attempt has a wall-clock deadline plus at most five seconds of
graceful cleanup; the wrapper enforces an outer deadline and kills descendants.
Unconfirmed cleanup/capability failure stops all later runtime starts and is
never retried. Other malformed/failed assessments have at most two attempts.
MaxAiCredits is a **per-session soft SDK limit**, not a hard monetary limit:
runtime 1.0.85 requires at least **30** (default), and smaller caller values are
rejected rather than lifted. The hard evaluator limits are sends and deadlines,
not billed cost or internal network retry count. Usage records contain observed
token units per attempt; billing and unavailable totals remain null.

**Verified smoke, 2026-09-25:** Windows/Python 3.11.9, SDK 1.0.14/runtime 1.0.85
authenticated and discovered `gpt-5.4-mini`; two independent tool-free SDK sends
on the public synthetic case returned valid structured responses. Initial
capability-only probes found the 30-credit minimum and registered builtin MCP;
neither sent assessment prompts. Explicit MCP disable/readback resolved the
gate. No runtime descendants remained after the successful wrapper returned.
This establishes SDK/auth/isolation viability only, **not** model accuracy,
historical fidelity, a 25-real-PR model trial, or production readiness.

## Targeted checks

```powershell
C:\pilot\venv\Scripts\python.exe -B -m unittest discover -s .\tests\signoff -v
$env:DEVPILOT_SIGNOFF_TEST_PYTHON = 'C:\pilot\venv\Scripts\python.exe'
Invoke-Pester .\tests\SignoffReplay.Tests.ps1
```

Tests cover a mixed 25-case synthetic replay, strict schemas/JSON, future and
fabricated references, label exclusion, hostile content as data, low support,
policy/history abstention, effective zero-tool gates, bounded attempts,
cancellation including teardown failure, exact resume, and output collisions.
There are no live tests in the offline suite.
