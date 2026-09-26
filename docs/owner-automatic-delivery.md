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

The Owner authority explicitly excludes class findings, advisory, `notEligible`,
`unknown`, uncovered evidence, relation capability, `wouldUpdate`, thread
status changes, resolve operations, votes, PR status, summaries,
notifications, and every other provider write. An existing exact comment is
`noOp`. A copied foreign marker, duplicate marker, stale body, changed source,
changed anchor, pagination failure, identity mismatch, or any other drift is a
refusal. The model runner remains `effectiveTools: []` and cannot see, request,
or authorize this phase.

The manual signed-selection writer remains available for human-controlled
creates or explicitly approved updates. Automatic service authorization uses a
different local key, policy kind, intent kind, outcome kind, directories, and
CLI. A human approval artifact cannot be substituted for a service policy.

## Independent test-class coverage delivery

The same create-only wrapper also supports the independently bound
`bpm-test-class-coverage@1` rule **and** capability. This is a separate,
default-off deployment decision; `autoCreateOwnerComments` never enables
coverage, and `autoCreateCoverageComments` never enables Owner. Coverage
accepts only completed live `coverage-v2-preview-cohort` observations with
class-level `violation` findings on changed MSTest classes and an exact
`wouldCreate` reconciliation. Its comment is the rule-bound
`devpilot-test-class-coverage:v1` marker/body, anchored to the changed class
declaration line. `noOp` does not write; `wouldUpdate`, ambiguous, foreign,
advisory, uncovered, or otherwise ineligible evidence does not write. The
writer accepts `noOp` only for a current, active, exactly anchored reviewer
thread containing the class marker and exact formatted body; sharing the
configured reviewer's account or GUID without that marker is never `noOp`.
Only `wouldCreate` can reach `CreateThread`. The `humanCovered`
classification is a human-review outcome, **not** `noOp`
or automatic eligibility; it cannot create a comment. A closed/outdated
human discussion from an earlier PR iteration may instead classify as
`unknown` (`historical-human-review-needs-review`), which also refuses
automatic delivery. A completed, model-free observation containing only this
specific kind of `unknown` (and no other unknowns) is readable so the writer
can emit a signed `action: none`, `outcome: refused` event per blocked class
with `historical-human-review-needs-review` diagnostic, zero writes, and
the prior thread/comment IDs and HTTPS URL when safely available. It does
not create another comment; if the observation also has `wouldCreate`
findings, that batch is refused pending operator review. Every other
`unknown` still fails closed. Even a completed `wouldCreate` observation is
refused if the live source head, current iteration, discussion snapshot, or
changed class line has drifted (for example, the declaration moved from line
25 to 26). Rerun observation against the new head before retrying; do not
reuse a stale decision. The existing signed policy is reusable only while
its exact rule, capability, reviewer, repository, and implementation
bindings remain valid.
The runtime calls only `ReadCurrent` and (after validation) `CreateThread`
for create-eligible observations; a historical-human refusal does neither.
it cannot update comments, statuses, votes, relations, or model output.
The shared evidence/proposal validator accepts coverage only when explicitly
selected by the automatic delivery caller. It requires a completed
`modelExecutionState: notAttempted` record, no model telemetry artifact,
and the bound coverage rule section and formatter output. The manual Owner
review and approval signer remains Owner-only and cannot authorize coverage.

Add the independent switch to an **external** toolkit config for the coverage
capability. An absent switch disables the single-state CLI, but the scheduled
coverage wrapper **requires the key to be explicitly present** before it
prepares or runs the cohort; literal `false` permits read-only scheduled
observation with delivery disabled:

```json
{
  "autoCreateCoverageComments": {
    "enabled": true,
    "policyPath": "C:\\private\\owner-v2-delivery\\policies\\coverage-v2-production.json",
    "policySha256": "<64 lowercase hex>"
  }
}
```

The signed `coverage-v2-service-authorization-policy` is separate from the
Owner policy and binds exact rule/capability identity, project/repository,
reviewer, toolkit and writer/provider/scheduler digests, `wouldCreate`,
`changed-mstest-class`, `violation`, and per-run/per-PR ceilings. Generate
it from a **completed live coverage** state identity while delivery is still
disabled:

```powershell
.\tools\Invoke-AutomaticOwnerV2Delivery.ps1 authorize-policy `
    -Delivery coverage `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -StateRoot C:\private\owner-v2-state `
    -Identity <completed-coverage-state-identity> `
    -ToolkitConfigPath C:\private\coverage-config.json `
    -PolicyId coverage-v2-production
```

Initialize the private key using `initialize-key` as above, then bind the
returned policy file SHA-256 in the coverage config. A single-state invocation
uses `invoke -Delivery coverage` with the same absolute paths and identity.
The scheduled wrapper selects coverage only for a coverage cohort manifest;
its `-EnableLiveModel` flag enables live **acquisition**, but the coverage
capability itself does not start or authorize a model. The scheduler's
aggregate create ceiling remains five across its completed coverage cohort,
with the signed per-PR limit checked against coverage delivery history.

Coverage signed intents, outcomes, and events use `coverage-v2-*` kinds;
the single-state and scheduled coverage results likewise use `coverage-v2-*`
kinds;
events share the authenticated event directory and include `ruleId`,
`capabilityId`, and the exact class name in `finding.symbol`. Owner events
retain their original kind and now carry their own rule/capability IDs as
well. Consumers must distinguish event kinds, verify HMAC envelopes, and
must not mistake a coverage event for an Owner event. The existing ambiguous
write block and interrupted-intent recovery rules apply unchanged.

## Redundant method-level coverage exclusion (toolkit only)

The single-state toolkit source
`tools/Invoke-AutomaticOwnerV2Delivery.ps1 -Delivery redundant-coverage`
accepts completed **live, model-free** observations for the separate
`bpm-redundant-method-coverage@1` rule/capability from a
`redundant-coverage-v2-preview-cohort` manifest. The rule path is
`src/DevPilot.OwnerCapability/Policy/redundant-method-coverage.v1.txt`.
Only `redundant-coverage-v2:<sha>` violation findings for changed,
method-level `[ExcludeFromCodeCoverage]` attributes on MSTest methods
inside an excluded test class are eligible. One bounded finding groups the
changed method attributes in that class: its symbol is the class name,
its anchor is the **first changed method attribute line**, and it carries
the count, ordered attribute lines, and up to 12 distinct identifier-only
method names. A truncated list must be flagged exactly when the affected
attribute count exceeds the displayed names; incoherent metadata refuses
delivery before provider access. It is not
anchored to the class declaration or a method signature. The formatter uses
the independently bound `devpilot-redundant-method-coverage:v1` marker and
asks to remove **only** the redundant method attributes.

This is **not** an update to the deployed scheduled task or its deployment
configuration. The redundant-method switch is absent/false by default;
neither `autoCreateCoverageComments` nor `autoCreateOwnerComments` enables
it. A disabled `invoke` reads the completed evidence but creates no local
delivery root, key, intent, or external comment. An enabled external config
would need this exact independent binding:

```json
{
  "autoCreateRedundantMethodCoverageComments": {
    "enabled": true,
    "policyPath": "C:\\private\\owner-v2-delivery\\redundant-method-coverage-v1\\policies\\redundant-coverage-v2-production.json",
    "policySha256": "<64 lowercase hex>"
  }
}
```

The toolkit `initialize-key -Delivery redundant-coverage` creates a
**separate** `redundant-method-coverage-v1` subroot under `-DeliveryRoot`
with its own `keys\redundant-method-coverage-service-authorization.hmac`,
policy, intents, outcomes, events, and locks. No Owner or class coverage
key, policy, event history, or create ceiling authorizes this mode. While
the switch remains disabled, `authorize-policy -Delivery redundant-coverage`
can sign `redundant-coverage-v2-service-authorization-policy` for an exact
completed redundant-method state identity. It binds the repository,
organization/project, rule/capability, reviewer, implementation digests,
`wouldCreate`, `changed-mstest-class-method-exclusions`, `violation`,
create-only authority, and independent per-run/per-PR caps (hard ceilings
5/50). For example, with private absolute paths:

```powershell
.\tools\Invoke-AutomaticOwnerV2Delivery.ps1 initialize-key `
    -Delivery redundant-coverage -DeliveryRoot C:\private\owner-v2-delivery
.\tools\Invoke-AutomaticOwnerV2Delivery.ps1 authorize-policy `
    -Delivery redundant-coverage -DeliveryRoot C:\private\owner-v2-delivery `
    -StateRoot C:\private\owner-v2-state `
    -Identity <completed-redundant-coverage-state-identity> `
    -ToolkitConfigPath C:\private\redundant-coverage-config.json `
    -PolicyId redundant-coverage-v2-production
```

The returned policy file SHA-256 must be bound in the independent config
before a toolkit `invoke -Delivery redundant-coverage` can deliver anything.
Do **not** run a live invocation merely to test this change; tests use
fake providers only. Live preflight and every candidate recheck require the
same active, non-draft PR source head, target/ref, current iteration, **every**
listed changed attribute line, exact reviewer identity, and complete current
discussions.
Only `wouldCreate` can call `CreateThread`, once. A current, unmarked,
affirmative plural human discussion on **any listed changed method attribute
line** (including a later line such as 36) covers the whole class as
`humanCovered`, never as a writer `noOp`. A question, negation, conflicting
discussion, or ambiguous identity fails closed. Earlier closed/outdated
human discussions produce a signed refusal event and block the batch for
operator review. `noOp` requires the exact current reviewer marker/body and
anchor. Foreign/cross-rule or duplicate markers, stale anchors/bodies,
`wouldUpdate`, ambiguous readback, and changed source refuse or block writes.
There are no updates, resolutions, votes, PR-status changes, summaries,
notifications, or model writes. Signed artifacts use distinct
`redundant-coverage-v2-*` kinds; an uncertain create is conservatively
counted and never blindly retried.

## Fail-closed configuration

### Named `Assert.AreEqual` arguments (toolkit only)

`tools/Invoke-AutomaticOwnerV2Delivery.ps1 -Delivery named-areequal` is an
independent, **default-off** create-only path for completed live, model-free
`bpm-named-areequal-arguments@1` observations. This does not deploy a
scheduler, enable a service, or post a comment. Neither the Owner, class
coverage, nor redundant coverage switch enables this rule. Its rule path is
`src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt`.
An absent switch or literal `false` on `invoke` reads the completed evidence
and returns `disabled`, without creating a delivery root, key, intent, or
provider write. Boolean `true` is invalid; an enabled *external* toolkit
config requires a signed policy file and its exact SHA-256 binding. The paths
below are synthetic examples, not deployment values:

```json
{
  "autoCreateNamedAreEqualComments": {
    "enabled": true,
    "policyPath": "C:\\example\\owner-v2-delivery\\named-areequal-v1\\policies\\named-areequal-v1-production.json",
    "policySha256": "<64 lowercase hex>"
  }
}
```

The independent `named-areequal-v1` subroot has its own
`keys\named-areequal-service-authorization.hmac`, `policies`, `intents`,
`outcomes`, `events`, and `locks`. Owner and either coverage key/policy/event
history cannot authorize or exhaust its caps. Initialize its key and sign a
policy from a completed live state identity while the switch is **off**:

```powershell
.\tools\Invoke-AutomaticOwnerV2Delivery.ps1 initialize-key `
    -Delivery named-areequal -DeliveryRoot C:\example\owner-v2-delivery
.\tools\Invoke-AutomaticOwnerV2Delivery.ps1 authorize-policy `
    -Delivery named-areequal -DeliveryRoot C:\example\owner-v2-delivery `
    -StateRoot C:\example\owner-v2-state `
    -Identity <completed-named-areequal-state-identity> `
    -ToolkitConfigPath C:\example\named-areequal-config.json `
    -PolicyId named-areequal-v1-production
```

Only a `named-areequal-v2:<sha>` *violation* with exact `wouldCreate`
reconciliation may create one `devpilot-named-areequal:v1` comment per
changed method. Its symbol is the full method name; its anchor is the first
changed violating call, and its bounded metadata records the integer call
count, strictly sorted unique changed call lines (at most 256), and an exact
truncation flag. Every listed line must still be changed in the current
iteration. The signed `named-areequal-v1-service-authorization-policy`
binds this rule, capability, repository, reviewer, implementation and
create-only authority, with independent per-run/per-PR ceilings (hard
maximums 5/50). Source head, target commit/ref, active non-draft PR,
current iteration, reviewer identity, discussion snapshot, finding metadata,
and changed lines are rechecked before each create. Only `ReadCurrent`
and `CreateThread` are permitted; readback must confirm one current,
exactly anchored reviewer marker and body. A same-account unmarked human
comment is **not** a bot `noOp`. Current affirmative human review blocks
creation; historical/outdated human review emits a signed no-write refusal
event and requires operator review. A foreign/duplicate/stale marker,
uncertain create, ambiguous readback, or drift fails closed. Signed
`named-areequal-v2-*` results, intents, outcomes, and events carry independent audit
and conservative write accounting. No updates, thread-status changes,
votes, PR statuses, summaries, notifications, relation writes, or model
writes are authorized. Tests use a fake provider; do not run a live `invoke`
merely to test this integration.

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
  "ruleId": "<rule section>",
  "capabilityId": "<bound capability>",
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
