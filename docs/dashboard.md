# Agent Review Dashboard POC

The dashboard is a small operational view over the JSONL metadata already
written by the `reviewer` and `review-handler` wrappers. It includes an optional
central roster that attributes reviewer activity to approved display names. It
is intentionally not an evaluation harness: it shows adoption, delivery, and
follow-through signals, not model precision, recall, or an employee productivity
score.

The POC has no database and no ingestion service:

```text
local agent JSONL
      |
      v
Export-AgentDashboardSnapshot.ps1
      |
      v
current sanitized snapshots
      |
      +--> Collect-AgentCommentOutcomes.ps1 (optional)
      |
      v
Build-AgentDashboard.ps1
      |
      v
dashboard/index.html
```

Everything runs in PowerShell 7. The generated site has no package manager,
framework, external JavaScript, font, analytics, or network dependency.

## Dashboard layout

The generated page is titled **Agent Review Dashboard** and presents six
summary cards, weekly activity, comment outcomes, an optional operator table,
recent pull requests, and the underlying reviewer-run table. Date labels use
UTC so viewers in different time zones see the same reporting buckets.

### Six summary cards

| Card | Definition |
|---|---|
| PRs reviewed | Distinct PRs with a completed reviewer cycle in the reporting period |
| Comments posted | Newly-created finding comments plus replies to existing review threads |
| Comment usefulness | Fixed divided by decided reviewer finding threads; a workflow proxy, not an accuracy score |
| PRs approved | Distinct PRs where the agent cast Approved or Approved-with-suggestions |
| PRs with code pushed | Distinct PRs where review-handler pushed a follow-up commit |
| PRs auto-completed | Distinct PRs where review-handler confirmed auto-complete |

### Weekly activity

The weekly chart shows distinct PRs reviewed, comments posted, PRs approved,
and PRs with code pushed. Snapshot PR-id sets prevent retries from inflating
distinct-PR counts.

### Comment outcomes

Comment usefulness is:

```text
Fixed / (Fixed + Won't fix + By design + Closed)
```

It applies to reviewer-opened finding threads on completed PRs. It measures
whether the team acted on decided findings; it does **not** prove that a
finding was technically correct. Merged-unresolved and still-open threads are
reported separately and excluded from the denominator. The dashboard displays
a low-volume warning when fewer than five comments have decided outcomes.

### Operator activity

When a roster is configured, the dashboard shows a sortable per-person
activity table with expandable PR history. It intentionally emits no composite
score or rank.

### Recent pull requests

The recent-PR table contains PR number, date, findings, posted comments, vote,
commit-pushed status, and auto-complete status. It contains no titles, authors,
comment text, code, commits, or file paths.

### Reviewer runs

The run table retains one row per live reviewer-model run. Idle polling and
preview promotion are excluded because neither is a new review run.

## 0. Configure the reporting window

Create (or copy from `samples/`) a `dashboard-data/dashboard-config.json` file
in your dashboard-data folder, and commit the generic template at
`dashboard/dashboard-config.json`:

```json
{
  "kind": "devpilot-agent-dashboard-config",
  "schemaVersion": 1,
  "reportingWindow": {
    "policy": "calendar-month",
    "year": 2026,
    "month": 8
  },
  "staleAfterHours": 48
}
```

**Why a fixed window?** Each operator runs the exporter independently. A
`calendar-month` policy computes identical `PeriodStart` and `PeriodEnd`
UTC boundaries from the year and month regardless of the day or machine clock
the export runs on. All 4–5 operators therefore produce byte-compatible
periods, and the builder rejects mixed-window snapshot sets rather than
silently producing wrong counts.

`staleAfterHours` controls when an operator's snapshot is marked stale in the
dashboard. Both the exporter and the builder auto-discover
`dashboard/dashboard-config.json` relative to the repo root; pass `-ConfigPath`
to override. Explicit `-PeriodStart` / `-PeriodEnd` CLI parameters always
override the config.

### Two-pass publisherId bootstrap

A publisher id is a stable, opaque 24-hex-character string generated once per
output slot and stored in the operator's local application data. It links a
snapshot file to a roster entry without embedding a name or alias.

**First run (bootstrap pass):**

```powershell
./tools/Export-AgentDashboardSnapshot.ps1 `
    -ReviewerLogPath C:\agent-state\reviewer\logs\reviewer.log.jsonl `
    -OutputPath C:\shared-dashboard-data\<opaque-slot>.snapshot.json `
    -ConfigPath ./dashboard/dashboard-config.json
```

The exporter prints the stable `publisherId` it assigned. Share that id with
the roster maintainer so they can add it to the roster before the first build.

**Subsequent runs (normal pass):**

The same command re-uses the persisted id from local application data. Each
operator keeps exactly one slot in the shared snapshot folder; overwrite the
same file on every export, and delete old files when an operator leaves or
changes slots.

### Roster and team-private synced folder MVP

1. Create a shared folder (e.g. a team OneDrive, SharePoint library, or SFTP
   path) that only invited operators can access. This is the **team-private
   synced folder**.
2. Each operator places their `<opaque-slot>.snapshot.json` there.
3. One designated builder has read access to all slots and runs the builder
   locally or from a scheduled job.
4. The roster (`dashboard-data/roster.json`) maps each `publisherId` to an
   approved display name and team. It is not committed to this repository.

### Roles and runbook

| Role | Responsibility |
|---|---|
| Operator (4–5) | Run the exporter after each snapshot period; overwrite their one slot |
| Roster maintainer (1) | Add/remove publisherIds, keep display names current |
| Builder (1) | Run the builder, publish the staging directory to Static Web Apps |
| Dashboard admin (1) | Manage Static Web Apps invited roles; rotate the period config each month |

**Monthly rotation runbook:**

1. Update `dashboard/dashboard-config.json` with the new year/month.
2. Operators export fresh snapshots using the updated config.
3. Builder rebuilds and republishes.
4. Archive old snapshots outside the shared folder (do not delete them from
   the repo — they were never committed).
## 1. Export a local snapshot

Point the exporter at one or both agent logs:

```powershell
./tools/Export-AgentDashboardSnapshot.ps1 `
    -ReviewerLogPath C:\agent-state\reviewer\logs\reviewer.log.jsonl `
    -ReviewHandlerLogPath C:\agent-state\review-handler\logs\review-handler.log.jsonl `
    -OutputPath C:\shared-dashboard-data\<opaque-slot>.snapshot.json
```

The default reporting period is the current UTC day plus the previous 27 days.
Use `-PeriodStart` and `-PeriodEnd` when every installation must publish an
identical fixed window. A date with no timezone is treated as UTC rather than
as the exporting machine's local timezone. Multi-installation builds require
identical windows and fail rather than label partial edge coverage as complete.

The exporter keeps a random, monthly rotating `installationEpochId` in the
current user's local application data. The state file is scoped by a hash of
the opaque output slot, so two dashboard publishers running under the same OS
account do not collapse into one installation. `-InstallationEpochId` or
`-InstallationStatePath` overrides that default. The id is used only to replace
duplicate exports from the same epoch; it is not an identity.

Schema-v2 snapshots also carry a stable opaque `publisherId`. It is generated
once per output slot, printed after export, and mapped to a display name only in
the central roster. Existing schema-v1 snapshots must be deleted and
regenerated.

Treat the shared snapshot folder as a **current-state inbox, not an archive**.
Each installation should overwrite its one opaque slot. When an installation
changes slots or rotates its epoch, remove the previous file. The snapshot does
not contain a stable identifier that could safely reconcile historical epochs.

Exact duplicate log events are ignored. Distinct-PR cards are deduplicated by
PR id. Preview promotion is represented by a separate delivery log record, so
posted comments and votes include both direct review delivery and later
promotion without counting a preview as a post. Delivery counts are treated as
newly-created events: the reviewer wrapper records
`newFindingCommentsPosted` and `newThreadRepliesPosted` separately from the
cumulative number visible after delivery. Retries and a new artifact that finds
the same comment already present therefore add zero. Earlier logs that predate
those fields use a cumulative-per-artifact approximation; regenerate forward
with the updated reviewer for exact comment counts.

Activity counts come from confirmed wrapper metadata. A host termination in the
narrow interval after Azure DevOps accepts a write but before its metadata event
is appended can undercount that write; there is no cross-system transaction in
this static POC. The PR itself remains the source of truth for delivery.

Snapshot aggregates remain validated for auditability, but the page renders the
individual run stream rather than the aggregate PR and weekly views.

### Privacy boundary

The snapshot contains only:

- UTC period and generation times;
- a random monthly installation epoch id;
- a stable opaque publisher id;
- aggregate counts;
- week-start dates and PR-number sets used for distinct counting;
- sanitized PR rows containing only PR number, date, finding count, posted
  comment count, review and vote times, vote, commit-pushed status, and
  auto-complete status.

It never copies raw comments, code, prompts, titles, authors, aliases, email
addresses, repository names, commit ids, file paths, local paths, model ids,
script hashes, error messages, or preview artifacts. Display names, teams, and
ADO identity mappings live only in the ignored central roster.

Create a roster from `samples/dashboard-roster.sample.json` and keep the real
file under `dashboard-data/`. A roster-enabled build fails when a current
publisher is unmapped or when one publisher/ADO identity maps to multiple
people.

The builder rejects a snapshot when its top-level totals disagree with its
sanitized PR rows.

## 2. Collect comment outcomes (optional)

The run table does not require Azure DevOps outcome polling. The collector
remains available when a separate structured usefulness artifact is needed.

To enrich it, run:

```powershell
./tools/Collect-AgentCommentOutcomes.ps1 `
    -SnapshotPath C:\shared-dashboard-data `
    -RosterPath C:\shared-dashboard-data\roster.json `
    -Organization <organization> `
    -Project <project> `
    -RepositoryName <repository> `
    -OutputPath C:\shared-dashboard-data\comment-outcomes.json
```

The collector uses the existing Agency ADO MCP connection, reads only PRs that
the current snapshots say received a posted comment, and writes aggregate
counts only. It recognizes a reviewer finding only when the first non-deleted
thread comment has both the reviewer's severity prefix and its automation
signature. The finding's publication time must fall inside a reporting period
for that PR.

The outcome file is bound to the exact selected snapshot bytes and their
reporting period and roster. Re-run the collector whenever a snapshot or roster
changes. The collector emits global and per-person usefulness counts without
copying ADO identities into its output.

`-FixturePath` replaces live ADO calls with an ADO-shaped JSON fixture. That
mode exists for offline validation and is used by
`tools/Test-AgentDashboard.ps1`.

## 3. Build the static site

Rebuilding the dashboard is one command:

```powershell
./tools/Build-AgentDashboard.ps1 `
    -SnapshotPath C:\shared-dashboard-data `
    -RosterPath C:\shared-dashboard-data\roster.json `
    -CommentOutcomePath C:\shared-dashboard-data\comment-outcomes.json `
    -OutputPath .\dashboard-data\index.html
```

The outcome path is optional. The builder:

1. validates every input;
2. selects the newest snapshot for each installation epoch;
3. deduplicates run IDs for the same publisher across installation slots;
4. maps each run's publisher to an approved roster display name and team;
5. emits one sortable run row with bounded metrics;
6. embeds the resulting bounded data into one dependency-free HTML file.

Missing snapshot paths and an empty period produce a friendly no-data page.
Malformed JSON, unsupported schemas, invalid types, and inconsistent totals
fail the build.

## 4. Validate

Run the end-to-end offline self-check:

```powershell
./tools/Test-AgentDashboard.ps1
```

It proves:

- duplicate cycles and duplicate delivery lines do not inflate the intended
  metrics;
- pre-period comment deliveries are not counted again by an in-period retry;
- an older snapshot from the same installation epoch is ignored;
- mixed reporting periods are rejected;
- schema-v1 snapshots and outcomes are rejected with regeneration guidance;
- publisher and ADO identities map to exactly one roster person;
- completed and failed run rows are retained and attributed;
- duplicate exported copies of one publisher's run are deduplicated;
- outcome classification excludes human threads with an agent reply and
  excludes summary threads;
- empty data renders;
- malformed JSONL and inconsistent snapshots fail closed;
- outcome data from a different snapshot set fails closed when supplied;
- generated JSON and HTML do not contain the synthetic raw text or local paths.

## Azure Static Web Apps

Do not generate real roster data into the tracked `dashboard/index.html`.
Generate a deployment staging directory under ignored `dashboard-data/`, copy
`dashboard/staticwebapp.config.json` into that staging root, and publish the
staging directory.

The checked-in config:

- requires the invited custom `dashboard_user` role for dashboard routes;
- redirects anonymous requests to Microsoft Entra sign-in;
- blocks the preconfigured GitHub login route;
- disables caching and adds restrictive response headers.

The preconfigured Entra provider allows any Microsoft account to authenticate,
but only accounts invited into `dashboard_user` can access dashboard content.
For a tenant-restricted sign-in boundary as well, configure a custom,
single-tenant Microsoft Entra provider and keep its client id and secret in
Static Web Apps application settings. Custom identity providers require the
Standard plan.

Do not add tenant ids, client ids, secrets, repository identifiers, or user
lists to this repository.

## Deliberate POC limits

This weekend implementation does not add:

- a database or event ingestion service;
- real-time updates;
- raw comment browsing;
- composite or ordinal employee rankings;
- memory, token, or cost reporting;
- golden-set precision or recall;
- complex filtering or drill-down.

Those require a separate evaluation or telemetry design rather than more cards
on this operational page.
