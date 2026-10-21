# Owner automatic delivery

`AutomaticOwnerV2Comments.ps1` is the production create-only delivery layer
above the completed Owner v2 observation and PR discussion reconciliation. It
does not give the model a tool or authorization. The scheduler runs the
read-only Owner observation first, and only the trusted wrapper can enter this
delivery phase.

```text
Owner prepare/run (model tools = [])
        |
completed live Owner observation
        |
discussion classification = wouldCreate
        |
signed deployment policy + live wrapper revalidation
        |
at most five anchored CreateThread calls
        |
readback + signed intent/outcome/event artifacts
```

This repository change does not register or modify a scheduler, deploy a key,
enable a policy, or post a live comment.

## Exact authority boundary

Automatic authority permits only an Azure DevOps `CreateThread` operation for
an exact completed `bpm-test-ownership@1` finding that:

- is a `violation` on one changed method-level MSTest construct;
- still has the exact immutable source head, method binding, and current
  changed-line anchor, so the completed missing-Owner finding still describes
  the live source;
- has the configured rule, capability, reviewer identity, toolkit head/tree,
  formatter, writer, provider, and scheduler digests;
- has a complete current discussion snapshot whose live classification is
  exactly `wouldCreate`; and
- remains on the same active non-draft PR source head, target commit, target
  ref, repository, project, and current iteration.

The authority explicitly excludes class findings, advisory, `notEligible`,
`unknown`, uncovered evidence, relation capability, `wouldUpdate`, thread
status changes, resolve operations, votes, PR status, summaries,
notifications, and every other provider write. An existing exact comment is
`noOp`. A copied foreign marker, duplicate marker, stale body, changed source,
changed anchor, pagination failure, identity mismatch, or any other drift is a
refusal. The model runner remains `effectiveTools: []` and cannot see, request,
or authorize this phase.

When a deterministic reviewer upgrade changes its current marker or formatter,
an earlier contextual comment can remain `noOp` only through authenticated
delivery history. The reader verifies the lane key on the signed create event,
intent, and outcome, links their run/event/state identities, requires the same
immutable PR source and target, rule content hash, construct identity, path,
line, and symbol, and then requires the exact live reviewer-owned comment,
thread ID, comment ID, body hash, active status, current context, and anchor.
The rule commit and implementation may advance while the authoritative rule
hash and construct remain identical. Copied, edited, deleted, moved, duplicate,
foreign-identity, stale-head, or changed-rule evidence remains unknown and
cannot authorize a create, update, or rewrite.

The contextual bundle also enforces EngHub's general named-call convention as
one rule group. A changed invocation, object construction, or `this`/`base`
initializer requires every supplied argument to be named when selected formal
parameters repeat a semantic type, each argument starts on its own line, or a
supplied value is a proven literal/compile-time constant. The implementation
uses a unique same-file/snapshot signature or a pinned known BCL signature and
never guesses parameter names. It excludes `Assert.AreEqual`, which remains
owned by the separate MSTest rule. Ambiguous overloads, dynamic calls, expanded
`params`, unsupported expression-tree syntax, or unknown language-version
evidence remain unknown and cannot reach delivery.

The contextual bundle's `pr-template-compliance` rule is PR metadata, not
changed-line analysis. It selects one effective
`/.azuredevops/pull_request_template.md` or `.txt` from the repository's
current default-branch commit and requires meaningful authored content under
Problem, Solution, and Validation. Bold-colon and equivalent ATX headings are
accepted; headings in fenced code or quoted examples are ignored. Copied empty
scaffolds do not satisfy the rule. Optional release notes, the optional full
test pass, conditional bundle/settings checks, and unchecked checklist items
are not required.

Its finding uses an explicit `pull-request` / `description` binding and is
delivered as a top-level PR thread with no file, line, symbol, or code anchor.
Evaluation and every live create preflight bind the exact description digest
and effective template path, ref, default-branch commit, blob, and content
digest. Description edits or template drift refuse the stale create. A
separate stable issue identity covers the same missing-section set and
identical effective template content, so an existing reviewer marker or
current human request remains a no-op across invalid description revisions or
a default-branch advance that preserves the same template blob/content.
Changed missing requirements require new proof; they are never blindly
promoted from history. Contextual automatic delivery remains create-only,
model-free, and capped at two creates per run and five creates per PR.

The additive `file-copyright-header` rule checks C# files in the current
changed-file inventory, including modified existing test files. It implements
the canonical EngHub CodingStyle.md **Copyright header** section at line 929
(commit `7cbaf3ef94e3bec3af10875b7c6a2690d111416b`): two dash-separator
comments around `// Copyright (c) Microsoft Corporation.  All rights reserved.`
before any code. BOM, LF/CRLF, and horizontal whitespace are supported. The
same notice may include a four-digit year or hyphen-separated year range;
historical years are accepted without annual rollover.
The rule does not require a year, inspect unchanged files, or
claim other languages are implemented. Generated, vendored, deleted, and
context-only files are excluded; unavailable source or comparison authority
is unknown, not compliance.

The finding uses a typed `file-header` anchor at the physical start of the
changed file, not a changed-line claim. Existing canonical path/span binding
is retained; separate header evidence binds source and comparison commits,
content digests, change type, and original rename path. The actual intake and
every provider create preflight derive that evidence from source and target.
Missing headers on new files or after header removal are introduced; a missing
header on both sides is explicitly **pre-existing and nonblocking**, not a
regression. Both kinds are nonblocking comments only. A current distinct human
copyright request anywhere in the same file suppresses a duplicate; a
markerless automation/reviewer-owned request or unproven prior context remains
unknown. Exact current reviewer-owned marker/body readback is a no-op.

When authorizing this additive bundle, retain four exact prior bindings:
the 18-rule bundle with only its 18 unchanged IDs, the 20-rule bundle with
only its 20 unchanged IDs, and the immediately prior 21-rule bundle with all
21 existing IDs, plus the 22-rule bundle with all 22 existing IDs. Use
`-PreviousRule*`, `-AdditionalPreviousRule*`, `-ThirdPreviousRule*`, and
`-FourthPreviousRule*` respectively. Never include `file-copyright-header`
in an old bundle's unchanged IDs, or `pr-template-compliance` in the 18/20/21
bundles. Existing create ceilings, run/PR history, idempotency, Owner behavior,
and model-free/create-only authority are unchanged. This source change does
not enable a live policy or perform any provider writes.

The manual signed-selection writer remains available for human-controlled
creates or explicitly approved updates. Automatic service authorization uses a
different local key, policy kind, intent kind, outcome kind, directories, and
CLI. A human approval artifact cannot be substituted for a service policy.

## Fail-closed configuration

`autoCreateOwnerComments` is absent or `false` by default. A true boolean is
invalid because it has no immutable policy binding. Enabled configuration is
external deployment data and has exactly this shape:

```json
{
  "autoCreateOwnerComments": {
    "enabled": true,
    "policyPath": "C:\\private\\owner-v2-delivery\\policies\\owner-v2-production.json",
    "policySha256": "<64 lowercase hex>"
  }
}
```

The policy path must be absolute, inside the private delivery root, owner-only,
and match the configured file digest. The HMAC-signed policy binds:

- exact project/repository, rule, capability, and reviewer identity;
- toolkit head/tree and formatter, manifest, approved-writer, provider,
  automatic-writer, and scheduler file digests;
- create-only/wouldCreate/method-violation authority;
- maximum creates per invocation (hard repository ceiling 5); and
- maximum creates per PR (hard repository ceiling 50).

Each signed run intent additionally binds the exact state identity, durable
result digest, observation file digest, source/target/ref, current iteration,
discussion snapshot, rule, capability, reviewer, implementation policy, and
ordered selections.

Initialize a private service key and authorize a deployment policy while
delivery is still disabled:

```powershell
$delivery = 'C:\private\owner-v2-delivery'
$tool = '.\tools\Invoke-AutomaticOwnerV2Delivery.ps1'

& $tool initialize-key -DeliveryRoot $delivery

& $tool authorize-policy `
    -DeliveryRoot $delivery `
    -StateRoot C:\private\owner-v2-state `
    -Identity <completed-owner-state-identity> `
    -ToolkitConfigPath C:\private\owner-v2-config.json `
    -PolicyId owner-v2-production `
    -MaxCreatesPerRun 5 `
    -MaxCreatesPerPullRequest 25
```

Record the returned policy path and SHA-256 in the external config, then use
the scheduler wrapper:

```powershell
.\tools\Invoke-OwnerV2ScheduledDelivery.ps1 `
    -StateRoot C:\private\owner-v2-state `
    -ManifestPath C:\private\owner-v2-cohort.json `
    -ToolkitConfigPath C:\private\owner-v2-config.json `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -EnableLiveModel `
    -LiveModel <qualified-model> `
    -LiveCredentialEnvironmentName COPILOT_GITHUB_TOKEN
```

There is no approval UI and no ask-user step. Configuration and signed policy
are the wrapper-owned deployment authorization.

## Delivery behavior

The wrapper holds an exclusive delivery lock and sorts Owner state/finding
identities deterministically. One scheduled invocation creates at most five
comments across the cohort. Every individual create receives a fresh read of
the PR, current iteration, changed source and anchor, reviewer identity, and
complete discussions. Read-only preflights have bounded exponential backoff,
and confirmed creates are paced before the next selection. The create is issued
once and is never blindly retried.

After the create, the wrapper reads the authoritative discussions and requires
one exact reviewer-owned marker/body. If a provider error occurred after the
write but the comment is visible, the outcome is
`created-confirmed-after-error`. If readback is unavailable or does not confirm
the comment, the marker is durably blocked as `ambiguous-post-write`; the
possible write is conservatively charged against both run and PR ceilings, its
event reports `providerWriteState: unknown`, and later automatic runs refuse
the entire PR until incident handling resolves the uncertainty.

An interrupted signed intent is reconciled before new work. One exact live
comment becomes `recovered-confirmed` with zero recovery writes. An absent or
ambiguous comment becomes `operator-review-required`; recovery never guesses
that a create is safe.

With nine eligible findings, isolated provider proof is:

1. first invocation: five creates, four remain;
2. next scheduled read/reconcile plus delivery: four creates;
3. next scheduled read/reconcile: all nine are `noOp`, zero writes; and
4. later hourly invocations: zero writes while the PR state remains unchanged.

## Durable delivery event feed

The dashboard-facing feed is the immutable signed files under:

```text
<delivery-root>\events\<event-id>.json
```

Consumers enumerate files, verify each HMAC envelope with the private
deployment key, parse `manifestJson`, and sort by `(occurredUtc, eventId)`.
They must not infer success from intents or process exit alone.

The stable payload is `schemaVersion: 1`,
`kind: owner-v2-delivery-event`:

```json
{
  "schemaVersion": 1,
  "kind": "owner-v2-delivery-event",
  "eventId": "<opaque id>",
  "runId": "<opaque id>",
  "occurredUtc": "yyyyMMddTHHmmssZ",
  "runHealth": "healthy|partial|refused",
  "subject": {
    "projectId": "<opaque id>",
    "repositoryId": "<opaque id>",
    "pullRequestId": 42,
    "sourceCommit": "<40 hex>",
    "targetCommit": "<40 hex>",
    "targetRef": "refs/heads/main"
  },
  "finding": {
    "stateIdentity": "<64 hex>",
    "findingId": "owner-v2:<64 hex>",
    "marker": "<64 hex>",
    "scope": "changed-line",
    "path": "tests/WidgetTests.cs",
    "line": 12,
    "symbol": "CreatesWidget"
  },
  "action": "create|none",
  "outcome": "created|created-confirmed-after-error|recovered-confirmed|noOp|refused|ambiguous-post-write",
  "threadId": 100,
  "commentId": 1100,
  "url": "https://dev.azure.com/...&discussionId=100",
  "modelWriteCount": 0,
  "providerWriteCount": 1,
  "providerWriteState": "none|confirmed|unknown",
  "diagnostic": {
    "code": "<stable code>",
    "message": "<bounded sanitized message>"
  }
}
```

For the PR-template rule, `finding.scope` is `pull-request`; the event carries
`subject: "description"`, `metadataSha256`, and `issueIdentity` instead of
`path`, `line`, and `symbol`.

No comment body, UPN, credential, token, raw provider response, or model packet
is in the event. IDs, path/line/symbol, hashes, URL, health, outcome, bounded
diagnostic, and write counts are sufficient for dashboard status and drill-in.

Scheduler result exit codes are truthful: `0` for healthy or disabled, `2` for
partial/cap-bounded work, `3` for refused delivery, and `1` for an unhandled
failure. A partial result may include confirmed creates; operators must read
the signed events and outcome.

## Disable, rollback, and incident response

The immediate disable switch is:

```json
{ "autoCreateOwnerComments": false }
```

Stop the scheduled wrapper or set that value before changing policy, key, or
provider configuration. Disabling delivery does not alter observations,
comments, manual approvals, or relation preview. Preserve keys, policies,
intents, outcomes, and events for audit. Never delete a provider comment as an
automatic rollback action.

For an ambiguous write, identity drift, duplicate marker, corrupted audit, or
unexpected provider count:

1. disable automatic delivery and preserve the private root;
2. inspect the live PR and signed intent/outcome/events;
3. reconcile the exact marker/body/thread manually;
4. correct or replace the external policy/configuration;
5. prove a private/fake canary with zero external writes; and
6. re-enable only after the block has a documented resolution.

## Key rotation

Keys are never stored in source, logs, model input, config, events, or policy
payloads. The delivery root and key must pass the harness private ACL checks.
To rotate:

1. disable and stop the scheduled delivery phase;
2. retain the old root read-only for historical verification;
3. initialize a new private delivery root/key;
4. authorize a new policy under that key;
5. atomically update the external path/digest binding;
6. run private/fake create, 5+4, no-op, recovery, and refusal canaries; and
7. resume the scheduler.

Do not overwrite a key in place: historical signed artifacts require the key
that created them.
