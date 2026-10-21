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
single PATCH, and readback. Connection identity requires both authenticated
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
vote, label, edit PR metadata, create or edit comments, change thread status,
or send a notification. A GET readback must confirm `abandoned` before the PR
ID is excluded from the same-cycle review cohort. Failed or ambiguous
transitions remain `unknown` and are not excluded.

Azure DevOps REST 7.1 does not expose a verified ETag, `If-Match`, revision, or
other optimistic-concurrency precondition for this PATCH. The immediate
reread is therefore a best-effort checked transition, not an atomic compare
and swap. A change can still occur between the last GET and PATCH. The signed
event records this limitation, and an ambiguous send is never blindly
retried.

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
maximum of two attempted status writes and 200 old candidates per run.

Initialize the private key and create a signed policy only after review:

```powershell
.\tools\Invoke-StalePrLifecycleAuthorization.ps1 initialize-key `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -ConfigPath C:\private\contextual-config.json

.\tools\Invoke-StalePrLifecycleAuthorization.ps1 authorize-policy `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -ConfigPath C:\private\contextual-config.json `
    -MaxAbandonsPerRun 2
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
