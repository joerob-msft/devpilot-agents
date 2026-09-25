# Owner reporting dashboard

The existing DevPilot Operations terminal dashboard can project the scheduled
Owner and relation service from verified local state. This is a read-only
reporting plane: it adds no HTTP listener, provider write endpoint, task
mutation, approval flow, credential prompt, telemetry upload, or deployment.
If reporting is unavailable or malformed, the reviewer scheduler continues
independently.

## Configure external roots

Copy `samples/owner-v2-reporting.config.json` to a private local location and
replace every example path and identity. All paths must be absolute.

```json
{
  "schemaVersion": 1,
  "kind": "devpilot-owner-reporting-config",
  "roots": {
    "state": "C:\\private\\owner-v2-state",
    "toolkit": "C:\\src\\devpilot-agents",
    "config": "C:\\private",
    "delivery": "C:\\private\\owner-v2-delivery",
    "manual": "C:\\private\\owner-v2-approvals",
    "runner": "C:\\private\\owner-v2-runner"
  },
  "files": {
    "toolkitConfig": "C:\\private\\owner-v2-config.json",
    "lastRun": "C:\\private\\owner-v2-runner\\last-run.json",
    "scheduledLog": "C:\\private\\owner-v2-runner\\scheduled-runs.jsonl"
  },
  "expectedToolkit": {
    "head": "<40 lowercase hex>",
    "tree": "<40 lowercase hex>"
  },
  "azureDevOps": {
    "organizationUrl": "https://dev.azure.com/example",
    "projectId": "<exact project id>",
    "projectName": "<display/project URL segment>",
    "repositoryId": "<exact repository id>"
  },
  "scheduledTaskName": "DevPilot Owner v2",
  "scheduledTaskPath": "\\",
  "refreshIntervalSeconds": 30,
  "staleAfterMinutes": 120,
  "budgets": {
    "maxFileBytes": 1048576,
    "maxFiles": 2000,
    "maxHistory": 500,
    "maxScanMilliseconds": 5000
  }
}
```

`state`, `toolkit`, and `config` are required. `delivery`, `manual`, and
`runner` are optional, but omitted sources are shown as unavailable rather
than inferred. `toolkitConfig` must be inside `roots.config`; formatter code
must be inside `roots.toolkit`; runner files must be inside `roots.runner`.
The adapter resolves every file under its declared root and rejects traversal,
symbolic links, junctions/reparse points, foreign real paths, oversized files,
and scans that exceed the count or time budget.

The automatic HMAC key is read only from
`delivery\keys\owner-v2-service-authorization.hmac`; the manual key is read
only from `manual\keys\owner-v2-comment-approval.hmac`. Each must be exactly
32 bytes and have restrictive permissions. Key bytes, credentials, UPNs,
provider responses, model packets, and raw configuration are never included
in the view model or rendered output.

`scheduledTaskName` and optional normalized `scheduledTaskPath` identify one
exact Windows task. Missing or ambiguous matches are reported unavailable;
the adapter never selects the first of multiple same-named tasks.

## Launch locally

Install and build the existing dashboard, then pass the reporting config to
the existing launcher:

```powershell
Set-Location <toolkit-root>\src\DevPilot.Dashboard
npm ci
npm run build

Set-Location <toolkit-root>
.\tools\Start-DevPilotDashboard.ps1 `
  -ReportingConfigPath C:\private\owner-v2-reporting.json
```

Reporting can be combined with the existing `-StateDir` and `-EventLogPath`
arguments. It can also run by itself. Direct Bun debugging uses:

```powershell
npm start -- --reporting-config C:\private\owner-v2-reporting.json
```

Press `d` in Simple or Advanced mode. The dashboard refreshes on the configured
interval; `r` refreshes on demand while the reporting overlay is open. Closing
the dashboard clears the timer. No watcher process is created.

## Views and filters

The reporting overlay extends the existing OpenTUI application:

- **Overview**: healthy/degraded/disabled/stale, last successful run age, next
  task run, toolkit/policy identity and caps, provider/model write counts.
- **Runs**: Owner/relation completed and failed counts, duration, attempts,
  model calls, pending/posted queue counts, writes, delivery outcome.
- **Findings**: PR, capability, rule, severity, reconciliation state, path,
  line, symbol, reason, and source-head freshness.
- **Deliveries**: automatic/manual create/update/preview/no-op outcomes,
  thread/comment IDs, write state, run/event IDs, anchors, body status, and
  validated Azure DevOps links.
- **Failures**: invalid signatures, ambiguous writes, refusals, drift, stale
  state, task failures, missing data, and recovery-required incidents.
- **Relations**: relation findings in a separate view, always labeled
  **READ ONLY / NOT WRITER ELIGIBLE**.

Use `Tab`/`Shift+Tab` for sections, Left/Right for `24h`/`7d`/`30d`/all,
`p` for all/pending/posted, `t` for all/automatic/manual, and `/` for search.
Search supports free text plus `pr:`, `capability:`, `health:`, and `outcome:`
tokens. Rows are sorted deterministically and capped by `maxHistory`. `o`
opens only the selected validated URL.

## Signed feed and body rules

Automatic delivery events are the PR172 immutable files:

```text
<delivery-root>\events\<event-id>.json
```

The adapter requires the exact `owner-v2-comment-signed-envelope` v1 contract,
HMAC-SHA256 verification, canonical `manifestJson`, and an
`owner-v2-delivery-event` v1 payload. Invalid, truncated, missing-ID, or
duplicate-ID events are quarantined and excluded from deliveries and counts.
Success is never inferred from an intent or process exit.

Manual intent/outcome audits use the distinct manual root and manual key.
They are verified with the same envelope rules and remain labeled manual.

The automatic event deliberately contains no comment body. Exact deterministic
text is displayed only when all of these local bindings match:

1. a verified service intent has the same run, state, finding, marker, path,
   line, and symbol;
2. the signed selection body hashes to its declared SHA-256;
3. the observation reconciliation body digest matches;
4. intent toolkit head/tree match the current toolkit config; and
5. the local formatter file digest matches the signed implementation digest.

If any binding is missing or mismatched, the dashboard displays only the
bounded body digest/summary and never reconstructs or guesses text.

## Direct-link validation

Links are rebuilt locally; the URL carried by an event is not trusted.
Organization URLs are restricted to HTTPS Azure DevOps organization forms.
Project and repository IDs must exactly match the configured identity, PR,
thread, comment, line, and path values must be valid, and path traversal is
rejected. The PR URL is always available after identity validation. A
discussion/comment/file anchor is added only when those IDs are present.

## Health semantics

- **healthy**: automatic policy and task are enabled, toolkit identity is not
  mismatched, verified feeds have no failures, and a successful run is fresh.
- **degraded**: quarantine, missing configured data, nonzero task result,
  toolkit drift, refusal, ambiguous write, unknown reconciliation, or
  recovery-required state exists.
- **disabled**: automatic policy is explicitly false or the task is disabled.
- **stale**: no successful run exists or its age exceeds
  `staleAfterMinutes`.
- **unknown**: required task/policy state cannot be established without a more
  specific disabled/degraded/stale condition.

Missing timestamps, task APIs on non-Windows systems, and absent optional
sources are explicit. A stale process or successful exit is not treated as a
successful review or delivery.

## Privacy and rendering

The dashboard is a local terminal process and opens no listening socket.
Untrusted strings are bounded and control characters are removed before
rendering. OpenTUI renders text, not HTML, so source/comment strings are never
inserted into an HTML or script context. Only locally verified deterministic
comment bodies can be shown. Raw provider payloads, model packets, credentials,
UPNs, keys, and unrestricted file contents are not projected.

Keep screenshots and captures private unless they contain only synthetic data.
The repository renderer fixture uses synthetic IDs, paths, and comments.

## Troubleshooting

- **Reporting unavailable**: validate absolute paths and confirm the config
  file itself is readable.
- **HMAC permissions are not restrictive**: repair the private root ACL; do
  not copy the key into the repository or loosen it for the dashboard.
- **Quarantine**: preserve the file and key, disable automatic delivery if a
  write may be ambiguous, and reconcile the exact marker/thread manually.
- **Toolkit mismatch**: compare expected head/tree with the external toolkit
  config and deploy only an intentionally authorized policy.
- **Task unavailable**: Windows Scheduled Tasks are reported only on Windows;
  other data remains readable on other platforms.
- **History truncated**: increase a budget deliberately after checking local
  file sizes; do not remove the bounds.
- **No exact body**: inspect the signed intent, observation body digest,
  toolkit identity, and formatter digest. The dashboard intentionally refuses
  partial derivation.

## Rollback and uninstall

No deployment is performed by this feature. To stop reporting, close the
dashboard and remove `-ReportingConfigPath` from the local launch command.
Optionally delete only the private reporting config. Do not delete state,
delivery events, audit roots, policies, or keys as an automatic rollback;
those artifacts are needed to verify historical writes. Disabling automatic
delivery remains the external toolkit setting:

```json
{ "autoCreateOwnerComments": false }
```

Removing reporting does not unregister or modify the scheduled task and does
not change provider comments.
