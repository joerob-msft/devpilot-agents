# Prospective sign-off observer (checkout preview)

The **default-off, read-only** `signoff-observer` role observes PR snapshots and
later outcomes for a persistent seven-day study. It reuses the strict
[replay engine](signoff-replay.md); it does not approve, comment, change code,
requeue checks, auto-complete, or contact PR authors. Existing Reviewer,
Review Handler, `Both`, Golden, and manual-dispatch defaults are unchanged.
`Both` still means the two operational roles, never the observer.

This is a development-checkout handoff, not a published release. Consumers
must use an explicitly selected `LocalToolkitRoot` preview override. Normal
release-managed deployment requires publishing and qualifying a toolkit
release containing these files first; do not change production pins to an
unpublished version.

## Prepare a study

Use PowerShell 7.4+, Python 3.11+, and the pinned dependencies described in the
replay guide. Runtime provisioning and authentication happen **before**
evaluation. No first-use downloads or automatic model fallback occur.
Actual workers require Windows Job Object descendant containment; there is
no uncontained fallback on other platforms.

The operator selects a fixed trusted consumer collector script and config.
They must have safe ownership/ACLs and no symlinks. Keep config, study state,
events, audit captures, and outbox outside tracked repositories in private
directories. Do not weaken workspace/root ACLs to bypass a failed check.
Prefer the consumer's initializer, which pins its collector and transitive
dependencies. For another consumer, construct this exact closed configuration
(`src\DevPilot.SignoffConfidence\schemas\observer-config.schema.json`):

```json
{
  "schemaVersion": 1,
  "studyId": "example-week-1",
  "stateRoot": "C:\\PrivateStudies\\example-week-1",
  "collector": {
    "scriptPath": "C:\\TrustedCollector\\Export-Observation.ps1",
    "configPath": "C:\\PrivateStudies\\collector.json",
    "scriptSha256": "<64 lowercase SHA256 characters>",
    "configSha256": "<64 lowercase SHA256 characters>"
  },
  "evaluation": {
    "mode": "collection-only",
    "model": null,
    "fixturePath": null,
    "runtimePath": null,
    "deadlineSeconds": 60,
    "maxAttempts": 1,
    "maxAiCredits": 30,
    "dailyLimit": 0,
    "studyLimit": 0,
    "exploratory": false
  },
  "pollSeconds": 900,
  "maxPages": 10,
  "maxItems": 25
}
```

Compute file pins with `(Get-FileHash -Algorithm SHA256 -LiteralPath
<path>).Hash.ToLowerInvariant()`. Placeholder pins above are deliberately
invalid, not a runnable collector or production configuration.

Collection-only is the default consumer configuration, with zero model
budgets. Explicit `offline` mode requires `fixture-v1` plus a fixture file and
accepts only synthetic cases. Explicit `live` mode requires a specific model,
preprovisioned runtime, and the additional `-EnableModel`/`-ObserverEnableModel`
launch switch. Set positive daily/study admission limits deliberately.
Changing modes/model/config/source/dependencies/runtime requires a **new study
root**; it never reuses results from a different pipeline.

## Launch and ownership

Validate without starting collection:

```powershell
$python = 'C:\PrivateTools\signoff-venv\Scripts\python.exe'
$config = 'C:\PrivateStudies\example-week-1.json'
.\src\Agents\signoff-observer\Start-SignoffObserver.ps1 `
  -ConfigFile $config -PythonPath $python -ValidateOnly
```

Observer-only attended TUI (no operational roles, broker, or manual actions):

```powershell
.\tools\Watch-DevPilotAgents.ps1 -Agent SignoffObserver `
  -ObserverConfigFile $config -ObserverPythonPath $python -PreviewOnly -Continuous
```

Use `-Once` for one bounded capture. Closing this TUI stops **its own** worker
tree. `-Golden`, `-Operational`, manual-role switches, and reviewer/handler
configuration are rejected in observer-only selection.

To add observation to an intentionally selected existing launcher, supply
`-EnableSignoffObserver -ObserverConfigFile $config -ObserverPythonPath $python`.
Its observer child is separate from the operational broker, never inherits
Golden/manual mutation capabilities, and is stopped when the owning TUI closes.
The existing two-role lifecycle is unchanged.

For a supervised week-long host, run this foreground command in an explicitly
managed terminal/process supervisor:

```powershell
.\src\Agents\signoff-observer\Start-SignoffObserver.ps1 `
  -ConfigFile $config -PythonPath $python -PreviewOnly `
  -StateDir C:\PrivateStudies\observer-events `
  -CancelFile C:\PrivateStudies\stop-observer
```

It does not self-detach, register a service/scheduled task, or deploy anything.
Use a stable awake host, private disk with sufficient space, pinned files,
and appropriate authenticated read access. Restart the **same** command after
an interruption; the original deadline and admission reservations persist.
Creating the cancel file stops work explicitly (exit 130); remove it only
when intentionally restarting. The deadline is not renewed.

An independent TUI can attach without acquiring worker ownership:

```powershell
.\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir C:\PrivateStudies\observer-events
```

Closing an attachment cannot kill the separately supervised worker.
Concurrent workers using the same study root fail the exclusive owner lock.

## Collector interchange

The toolkit invokes only the hash-pinned operator-selected script:

```text
pwsh -NoProfile -NonInteractive -File <collector>
  -ConfigFile <collectorConfig> -RequestPath <request.json>
  -OutputPath <response.json> -LocalToolkitRoot <toolkit>
```

No command comes from PR content or model output. The collector owns read-only
provider access; it must enforce its own tool allowlist and pin transitive
code/config. The toolkit cannot turn arbitrary trusted PowerShell into a
read-only sandbox. Neither the SDK nor its prompt receives the collector,
ADO/GitHub/WorkIQ clients, provider credentials, shell, or network tools.

Authoritative versioned JSON Schemas are shipped under
`src\DevPilot.SignoffConfidence\schemas`:

| Schema | Contents |
|---|---|
| `observation-request` | Study/capture IDs, startedAt, cursor, known PR families, page item limit, collector-config hash |
| `observation-page` | Matching IDs/cursor, capture window, bounded inventory, snapshots, separate outcomes, explicit gaps |
| `bundle` | Existing v1 evidence/provenance/completeness/guidance; unchanged by observation |
| `observer-adjudication` | Separate explicit human judgment of a persisted decision |
| `observer-delivery` | Separate private-operator report delivery authorization/configuration |

Pages must terminate explicitly; absence is never interpreted as completion.
Incomplete pagination records a gap and admits no assessments that cycle.
One-shot failed/incomplete capture exits 2, not success. Private per-capture
`collector.stderr.log` receipts retain operator diagnostics; they never enter
model inputs, event messages, or public reports.

Snapshot evidence is bound to source **and** target commit and iteration.
Capture time, evidence cutoff, and human event time are distinct. Current
observations remain `CURRENT_SNAPSHOT`; they are not relabeled historical
`EXACT`. Duplicate polls, votes, outcomes, and transport timestamps do not
create new evaluations. Code/intent/policy/check/discussion content and head
changes do. Collectors should project stable finish times and freshness
boundaries, not a continuously changing age counter.

Labels are forbidden in prospective capture bundles. Outcomes, baseline votes,
merge/completion state, family identifiers, and future labels do not enter
the model prompt. Initial already-approved and unknown baselines remain
separate from prospective unapproved enrollment. Unknown/missing provider
policy, test coverage, full code, intent, event timestamps, or actor identity
are not fabricated.

## Ledger, policy, budgets, and reports

`observer.sqlite` stores append-only capture, enrollment, state-transition,
snapshot, admission, decision, outcome, adjudication, and report history.
Update/delete triggers guard accidental mutation, not a malicious disk owner.
Report SHA256s detect corruption, not cryptographic authenticity.
Original predictions are committed before later outcomes; late-arriving
human events can disqualify them retrospectively without rewriting them.
Out-of-order observations cannot replace current state. Terminal/reopened
transitions are retained; unchanged evidence on reopening is not reinferred.
Inventory-only families are **UNKNOWN**, not falsely counted as natural
model coverage. Enrollment cohort remains fixed; any later predictions for
an initially unclassified family remain in that UNKNOWN denominator rather
than appearing as decisions under a cohort with zero enrolled families.

Study configuration, model, engine/prompt/aggregate policy, dependency/runtime
and containment source are frozen. Guidance content/revision is pinned by ID
and per-family guidance set. Changed approved guidance requires a new study.
Snapshot-specific provider policy/test evidence may change and triggers a
new fingerprint; this is not an engine-policy change.

Daily UTC and study limits count **admitted evaluations**, reserved before
inference, independently of credits. Each evaluation uses at most two runs
and at most two attempts per run. Interrupted reservations are consumed with
unknown usage, never automatically resent. Budgets stop model admissions,
not read-only collection. Expiration stops new work after seven days; already
admitted work remains bounded by its run deadlines. Poll/page/item limits
bound capture batches. There is one assessment at a time.

`maxAiCredits` is the released SDK's **soft per-session** limit, with its
minimum of 30; it is not a hard daily/study currency budget. Never silently
increase a caller's smaller cap. Exact usage/backend versions remain null
when unavailable. Fresh same-model sessions may be correlated, not
statistically independent.

Final `APPROVE` requires complete applicable code/intent/policy/validation,
two valid LOW-risk/all-YES/no-blocker outputs, and both raw direct estimates
at least 0.9. This uncalibrated heuristic is **not authorization or a calibrated
probability threshold**. Known code-check failure can produce
`REQUEST_CHANGES` without a model. Infrastructure gaps and unknown policy
abstain. Optional exploratory code/intent diagnostics remain separate from
the final abstention. Runtime capability/cleanup failure durably blocks model
restarts for that study and exits for outer containment cleanup; a later
restart can continue collection only.

Reports are under `reports\<SHA256>.json`, with daily, `latest`, and (after
deadline) `final` JSON/Markdown pointers. The dashboard shows capture health,
families/admissions/comparisons, the last evaluated family's final policy
separately from its diagnostic, eligibility gaps, deadline, and report path.
An incomplete capture stays visibly actionable.

Reports retain natural/synthetic/unknown families, decisions, abstentions,
no-prediction and censored denominators. Prospective policy agreement selects
the latest eligible **live natural** prediction for the exact family and both
heads/iteration, finished strictly before a known human approval/change
request. Timezone offsets compare as instants. Bots, unknown actors/times,
baseline approvals, late predictions, policy-ineligible diagnostics, and
synthetic fixtures do not qualify. Completion/abandonment are observations,
**not readiness ground truth**. Lead time is not measured time saved.
Polling can miss transient states; no completeness or accuracy claim follows
from a fixture trial or only positive examples.

For human adjudication, create an `observer-adjudication` JSON file referencing
a persisted `decisionId` and exact evidence IDs, then explicitly import it:

```powershell
.\src\Agents\signoff-observer\Start-SignoffObserver.ps1 `
  -ConfigFile $config -PythonPath $python -AdjudicationFile C:\PrivateStudies\judgment.json
```

This takes the same owner lock (stop the worker first), preserves separate
operator judgments, and starts no collector/model calls. It never silently
relabels ADO outcomes or model evidence.
For a live-configured study the command also requires `-EnableModel` to pass
the configuration gate; the adjudication-only branch still makes no SDK calls.

## Optional private WorkIQ report delivery

Delivery is **off by default and not part of the observer's authority**.
The separate `tools\Send-SignoffObserverReport.ps1` dispatcher requires all of:
`enabled:true` in a private delivery config, explicit `-EnableDelivery`, an
exact existing operator chat ID, `privateOperatorDestination:true`, and an
immutable report hash already committed in the study ledger.

The closed config fields are `schemaVersion:1`, `enabled`, `studyId`,
`studyRoot`, separate private outbox `stateRoot`, `chatId`, and
`privateOperatorDestination:true`. Use only a private study-operator
destination, never PR participants; influencing their decisions would
contaminate the observation. Do not put private destinations in this repo.

```powershell
.\tools\Send-SignoffObserverReport.ps1 -ConfigFile C:\PrivateStudies\delivery.json `
  -ReportPath C:\PrivateStudies\example-week-1\reports\<SHA256>.json `
  -AgencyPath C:\TrustedTools\agency.exe -PythonPath $python -PreviewOnly
```

`PreviewOnly` is terminal and forbids delivery even with `-EnableDelivery`.
An explicitly authorized invocation without preview sends only an escaped
summary to `/chats/<exact-id>/messages`, using `create_entity` only. It does
not discover recipients, create chats, mention authors, or add PR references.
The outbox records unknown **before** sending. Confirmed and unknown attempts
are not automatically resent; an ambiguous send requires manual operator
reconciliation. Teams content is never ground truth or model evidence.
No actual WorkIQ send is part of the offline tests.
