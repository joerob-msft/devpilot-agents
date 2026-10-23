# Stale pull request lifecycle

The stale pull request lifecycle is a bounded phase of shared review
acquisition. It runs after the existing two-pass active pull request inventory
is reconciled and before any review head, changed file, or discussion
acquisition. It does not add a task, worker, model, or polling loop.

The feature is disabled by default. This change does not authorize a deployed
policy, create a production key, update the scheduled task, or abandon a live
pull request.

## Eligibility

One UTC cutoff is frozen for each run:

```powershell
[DateTime]::UtcNow.AddYears(-1)
```

An AzureUX-BPM pull request is eligible only when all of these facts are
proven:

- its status is `active`;
- it is not a draft;
- its target is exactly `refs/heads/master`;
- its creation time is strictly before the cutoff; and
- its latest counted activity is at or before the cutoff.

Counted activity is deliberately limited to:

- source push occurrence time from the pull request iteration push;
- iteration creation and update time; and
- publication, reply, or content/update time of an actual non-system comment
  by any actor, including automation.

Commit author and committer dates are never push evidence. PR title,
description, labels, votes, service statuses, and system-only thread events do
not refresh the lifecycle clock. A system thread may contain an actual
non-system comment; that comment still counts.

When an iteration summary provides a push ID but omits its date, the provider
loads that exact Git push once per push ID and requires the returned push ID,
repository, project, and date to match. It does not request or require optional
ref updates. Missing or mismatched push details remain unknown.

During initial qualification (`Phase = 'decision'`), after loading live PR
metadata, iterations, discussion threads, and the source branch ref, the
provider evaluates iterations newest-first for a counted activity witness
strictly after the frozen cutoff. If live discussion comments or iteration
timestamps already prove recent activity after the cutoff, or once the newest
iteration push proves activity after the cutoff, older iteration push-detail
GETs are not required to establish `recent-activity`. In that early-witness
qualification branch, `complete = true` and `latestActivityUtc` record the
proven recent-activity witness strictly after the cutoff (rather than an
exhaustive maximum across older skipped pushes), and `activityDigest` binds the
observed recent-witness activity set. When `-LifecycleRoot` and
`-Key` are supplied, verified push timestamps are persisted as write-once
HMAC-signed records under `pushes\<pullRequestId>\push-<pushId>-iter-<iterationId>.json`
(kind `stale-pr-push-date-v1`) so interrupted multi-push PRs can resume across
runs and previously verified push timestamps do not require repeated live
`/pushes/{pushId}` GETs on subsequent qualification runs. Cached push dates
never authorize a transition: when no counted activity is strictly after the
cutoff, or during `Phase = 'prewrite'` immediately before any status write,
every push date omitted by the iteration summary is verified live across all
iterations before computing `activityDigest` or authorizing abandonment.

Signed per-PR activity proof records under
`activity-proofs\<pullRequestId>\seq-<NNNNNNNN>-<state>.json` (kind
`stale-pr-activity-proof-v1`) require all 13 current identity and freshness
fields (`projectId`, `repositoryId`, `pullRequestId`, `status`, `isDraft`,
`sourceRef`, `targetRef`, `sourceCommit`, `targetCommit`, `iterationId`,
`creationUtc`, `latestActivityUtc`, and `activityDigest`) plus matching policy
and evidence digests and `latestActivityUtc > CutoffUtc`. Partial inventory
records (including the 5-key normalized inventory shape from
`Discover-ActivePrInventory`) are never accepted as cached proofs and always
require live provider evaluation (at least 4 live GETs per non-locked old PR for
metadata, iterations, threads, and source ref, plus 1 GET for the newest push
on cold runs and 0 push GETs on warm runs once the push-date record is signed).
Accordingly, on a 60-old-PR cohort (`57` non-locked old PRs), a single 128-GET
cycle evaluates up to `31` non-locked old PRs per run and still ends with a
budget deferral, traversing the full 60-PR cohort across 2–3 cursor-rotated
runs rather than achieving zero global deferrals per run from 5-key inventory
alone. Cache reads and writes use lazy `.NET` streaming directory enumeration
(`[IO.Directory]::EnumerateFileSystemEntries` with `ReparsePoint` skipping,
stopping immediately at `max + 1`) and enforce bounded per-PR file counts
(`256` push files, `64` recent-activity proof files plus one terminal
`withheld` retirement record), per-file (`64 KiB`) and per-PR total byte
ceilings (`4 MiB` push cache, `1 MiB` activity-proof cache), shared provider
clock deadlines wired through all caller sites, and static non-boolean integer
and safe-ID validation. When a PR's valid activity-proof history reaches the
64-version cap on subsequent head/activity changes, the chain appends a
terminal `withheld` record (`seq-00000065-withheld.json`) and continues using
the live recent-activity witness without failing closed or blocking review
eligibility. Any cache corruption, tampering, or invalidation-write failure
fails closed (`unknown` / `activity-evidence-unknown` with structured
`cache-write-failed` or `cache-invalidation-failed` diagnostics) and never
leaves a superseded proof reusable.

Missing continuation proof, count mismatches, malformed timestamps, unknown
comment types, inconsistent source refs, unavailable endpoints, or any other
ambiguous required evidence produce `unknown` and zero writes.

All lifecycle reads in one provider instance share the lower configured read
ceiling and one deadline. The counters are not reset per PR, prewrite, push
detail, or readback. Exhaustion before a decision or prewrite defers that PR
with zero writes and stops the current run. The result records a bounded
diagnostic that distinguishes the read-count, response-size, and deadline
branches without retaining a URI, token, header, or response body. It also
records the next old candidate, and shared acquisition resumes from that
candidate on the next compatible run instead of starting with the same
pathological PR again. Exhaustion after the single PATCH leaves the transition
ambiguous and never authorizes a retry.

Automatic review comments use a stricter per-PR gate than read-only
enumeration. A fresh PR created within the cutoff remains reviewable without
extra lifecycle reads. An older PR is included in automatic-comment snapshots
only after complete lifecycle evidence proves activity after the cutoff.
Confirmed abandoned PRs are excluded. Old PRs with permanent write locks,
budget deferrals, incomplete evidence, or no completed lifecycle decision are
retained as `lifecycle-activity-unverified` and withheld from every automatic
comment lane. They are neither treated as abandoned nor marked complete.

Shared acquisition also advances its ordinary head cursor after each selected
batch even when one head has durable file progress. The progress record remains
bound to the exact code head and is revisited after later cohorts, preventing a
large or temporarily unknown PR from pinning all review lanes indefinitely.

The provider obtains the existing Azure DevOps AAD resource token once in
memory and uses direct HTTPS for connection identity, every lifecycle GET, the
single PATCH, optional explanation POST, and their readbacks. Connection identity requires both authenticated
and authorized user IDs plus the subject descriptor to match the signed actor.
The token, headers, raw responses, and arbitrary server text are never written
to lifecycle audit records.

## Checked transition

The initial decision is read-only. Immediately before a write, the lifecycle
provider reloads status, draft state, source and target refs, current source
head, target head, iterations, pushes, and actual comments. Any change in the
bound evidence digest withholds the write.

An eligible transition writes exactly this body once:

```json
{ "status": "abandoned" }
```

It never deletes the source branch and cannot merge, transition work items,
vote, label, edit PR metadata, edit comments, change thread status,
or send a notification. A GET readback must confirm `abandoned` before the PR
ID is excluded from the same-cycle review cohort. Failed or ambiguous
transitions remain `unknown` and are not excluded.

Azure DevOps REST 7.1 does not expose a verified ETag, `If-Match`, revision, or
other optimistic-concurrency precondition for this PATCH. The immediate
reread is therefore a best-effort checked transition, not an atomic compare
and swap. A change can still occur between the last GET and PATCH. The signed
event records this limitation, and an ambiguous send is never blindly
retried.

## Bounded abandonment explanation

A new, explicit `authority.abandonmentExplanation` grant in the **lifecycle**
policy permits one create-only explanation after this run's single confirmed
status transition. Without that grant, including under existing status-only
policies, no explanation is read or posted. Ordinary Owner, Named, and
contextual comment authority and quotas are unchanged.

The deterministic body says the PR was automatically abandoned because it
was created more than one year ago and had no counted activity since the
frozen cutoff. It includes UTC creation, cutoff and latest counted-activity
timestamps, the counted/excluded activity definition, the frozen evidence
digest, and `<!-- devpilot-stale-abandonment:v1:<status-intent-id> -->`.
No mutable title, description, actor name, token, or server response is copied
into the explanation. Eligibility and evidence remain frozen **before** either
write. The explanation is a real non-system bot comment and counts as activity
on subsequent evaluations; it is never exempted from the all-actor clock.

Complete same-PR discussion reads check for that marker before the POST and
confirm exactly one root text comment with the exact body and authorized
actor afterward. Conflicting/duplicate markers or incomplete history fail
closed. A permanent exclusive reservation and signed intent precede the
attempt. There is at most one explanation attempt per transition and run,
without increasing the one status-attempt cap, 200-candidate cap, 128-GET
ceiling, 16 MiB response ceiling, or 240-second shared deadline. Lower
configured read/time ceilings still apply. Explanation GETs share, rather
than reset, the lifecycle provider's budget.

Before signing a confirmation, the native lifecycle consumer independently
checks the provider's exact seven-field dictionary: matching PR, body digest
and actor, exactly one marker, and positive integer thread/comment IDs.
Malformed or mismatched readbacks remain unknown with the attempted write
preserved; unverified provider payloads are not copied into the signed ledger.

Status success followed by comment failure remains a confirmed abandonment,
with `health = unknown` and separate attempted and unconfirmed action counts.
There is no rollback, blind POST retry, historical-abandonment backfill, or
green result inferred from an unknown outcome. An unresolved explanation also
blocks a later transition on the same PR until exact reconciliation.

`Resolve-StalePrLifecycleExplanation` is read-only against Azure DevOps and
accepts one exact PR/status-intent identity, the same policy/key, and the
lifecycle provider. It verifies the signed status transition and explanation
intent before rereading the exact marker/body/actor. It never posts. Local
reconciliation events and confirmation receipts are additive and immutable;
the original uncertain outcome is retained.

Shared acquisition exposes `lifecycleStatusWrites`,
`lifecycleExplanationWrites`, their `lifecycleUnconfirmed*` counterparts,
`lifecycleProviderReadCount`, and `lifecycleExplanationReadCount`.
`providerWrites` and `lifecycleProviderWrites` are the sum of attempted status
and explanation actions, not the number of abandoned PRs.
`unknownPossibleEffect` derives from unconfirmed actions, not from total
writes minus confirmed abandonments. The aggregate `providerReadCount` also
includes lifecycle GETs; `intakeProviderReadCount` retains the ordinary intake
component. Both dictionary and native
`PSCustomObject` results preserve those effects, confirmed exclusions, and
event streams even if subsequent cursor validation fails.

Legacy status-only results remain supported only when all four new action
counters are absent. Presence of any attempted or unconfirmed counter,
including an explicit null, requires the complete valid four-counter group.
Invalid groups withhold automatic review eligibility, retain bounded reported
aggregate writes, and expose untrusted action counts as null with an unknown
possible effect. Shared-acquisition output preserves those nulls rather than
turning them into zero writes or attributing all writes to status transitions.

## Separate authority and audit

Lifecycle authorization is independent of every comment writer. Its private
root is:

```text
<automatic-delivery-root>\stale-pr-lifecycle-v1
```

It has a distinct HMAC key, signed policy, intents, outcomes, events, and
lock namespace. The policy binds the exact actor, project, repository,
master/non-draft scope, one-calendar-year thresholds, counted and excluded
activity kinds, implementation digests, `status:abandoned` authority, and a
maximum of one attempted status write and 200 old candidates per run. The
optional explanation grant binds the exact template, one attempt per run and
transition, mandatory exact readback, and no ambiguous POST retry. It does
not relax `commentsOrThreads = false` for general-purpose comments.

The existing `intents`, `outcomes`, and root `events` remain **status-only**.
Explanation records use `explanations\intents`, `explanations\outcomes`, and
`explanations\events`, with kind `stale-pr-abandonment-explanation-v1-*` and
action `comment:create-after-confirmed-abandonment`. Read-only reconciliation
events have `operation = reconcile`, `providerWriteCount = 0`, and retain
`originalAttemptCount` (null if a crash left no original outcome, with an
explicit `originalAttemptCeiling = 1`). Consumers must not treat them as new abandonments or
ordinary rule comments with `finding`/`stateIdentity`. Confirmation receipts
and reconciliation outcomes live under `explanations\confirmations` and
`explanations\reconciliations`. All use the existing lifecycle key.

Initialize the private key and create a signed policy only after review:

```powershell
.\tools\Invoke-StalePrLifecycleAuthorization.ps1 initialize-key `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -ConfigPath C:\private\contextual-config.json

.\tools\Invoke-StalePrLifecycleAuthorization.ps1 authorize-policy `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -ConfigPath C:\private\contextual-config.json `
    -MaxAbandonsPerRun 1 -EnableAbandonmentExplanation
```

Then bind the returned policy path and file SHA-256 in external deployment
configuration:

```json
{
  "stalePullRequestLifecycle": {
    "enabled": true,
    "deliveryRoot": "C:\\private\\owner-v2-delivery",
    "policyPath": "C:\\private\\owner-v2-delivery\\stale-pr-lifecycle-v1\\policies\\azureux-bpm-stale-pr-lifecycle-v1.json",
    "policySha256": "<64 lowercase hex>"
  }
}
```

Use the literal `false` to disable the phase. A bare `true` is invalid.

## Operator-owned rollout

This feature does not deploy itself. Review and install a clean, exact
head/tree and the five raw implementation digests bound by the lifecycle
policy. Reauthorize to a **new** policy file using the existing lifecycle key
and `-EnableAbandonmentExplanation`; rebind its path/SHA-256 in the existing
Named shared-acquisition configuration. Old policy files remain immutable.
Rebind the existing deployment's exact toolkit/provider/runner digests as
required by its validators; do not copy whole modules into other lineages.

Before enabling, review private scheduler consumers for the disaggregated
effect fields and additive explanation stream described above. Status-only
root-ledger readers remain compatible, but operational reports need explicit
explanation enumeration to report comment outcomes. Verify a normal current-PR
transition and exact comment readback through the existing scheduled route.
Synthetic providers and local checks are not evidence of production delivery.
Never retry previously ambiguous status writes or backfill earlier abandoned
PRs to obtain rollout evidence.
