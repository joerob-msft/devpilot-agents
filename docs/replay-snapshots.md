# Offline snapshot replay

A reviewer cycle reads a pull request from a repository host. Once that pull
request moves on, the evidence that produced a particular review is gone, and
"we fixed the miss" becomes an assertion nobody can check.

Replay closes that gap. An operator records the reads one cycle made, and a
later build of the agent re-runs the **whole** stack against those exact bytes:
source transport, convention packs, review facts, both generalist passes, the
convention specialist, cross-verification, the delivery gate and every preview.
No repository is contacted.

## What replay is, and what it is not

Replay is **evidence about a recorded pull request state**. It is not a review,
and it is not a reproduction of a live run.

- It is permanently preview-only. Every write switch, every gate switch and
  both promotion paths are refused at startup, the delivery authorization is
  forced to `PreviewOnly` whatever the pass count, and the artifacts it writes
  are sealed under a separate key domain so promotion cannot verify them.
- The model's tool grant is denied. The wrapper's own reads come from the
  snapshot, but a model tool would reach the host through the CLI's
  credentials, not through the replayed session, and the local file tools would
  read the working tree, which is neither the snapshot nor the reviewed commit.
  So in replay the entire code-defined tool ceiling goes on the deny list.
  Each pass keeps its own allow list - substituting one would offer a pass a
  tool its own ceiling withholds - and the deny always wins, so nothing in it
  survives. It is denied rather than emptied because an empty allow list makes
  the launcher omit the tool flags entirely, which restores Copilot CLI's
  default discovery. The model therefore cannot look anything up for itself,
  which makes a replay a **lower bound** on what a live run would find. The
  preview says so in as many words.
- Replay state is separate state. A replay writes under
  `<StateDir>/replay/<snapshotId>/`, so it cannot burn a real pull request's
  attempt budget, supersede its gate decisions, or leave preview artifacts a
  later live run would read back.

## The seam

Almost every repository read in this toolkit goes through `Send-AgentMcpRequest`.
A replay session is served there, which is why the layers above it need no
changes and see no difference: `Invoke-AgentMcpTool` still validates the
envelope, `ConvertFrom-AgentMcpResourceContent` still enforces the exact URI,
the MIME allow-list, canonical base64, the size bound and UTF-8 strictness. A
replayed payload gets exactly the hostile-input treatment a live one gets.

A replay session has no process and no socket. There is no code path from one
to the network:

- only `tools/call` is answered; `initialize` and every notification are refused;
- a tool or action outside the code-defined read ceiling is refused, at load
  time so a snapshot cannot contain one, and again at serve time so no caller
  can ask for one;
- a read the snapshot does not carry throws, naming the exact request. It never
  falls through to a live read.

**"Almost" matters.** The MCP seam is one of two source transports. The Azure
CLI source fallback (`review.sourceTransport.azureDevOpsCliFallback.enabled`,
see [source-transport.md](source-transport.md)) does not go through
`Send-AgentMcpRequest` at all: it resolves `az` on `PATH`, runs it, and then
calls the REST API directly. Treating the MCP seam as the only egress is exactly
the assumption that once let a configured replay contact the live service, so
replay refuses that transport in three places:

- the MCP capability probe is short-circuited in replay, so it neither contacts
  anything nor reports a capability the snapshot cannot serve. A consequence
  worth knowing: source is therefore always served by the snapshot-backed legacy
  path, even when the recorded run used the newer `get_changes` contract, so
  source coverage and span basis in a replay can differ from the live run the
  snapshot records;
- `Get-ReviewerSourceTransport` declines the fallback branch in replay and falls
  through to the snapshot-backed path, so the run stays consistent rather than
  half live, and a read the snapshot lacks still fails closed there;
- `New-ReviewerSourceAzCliInvoker` refuses outright, whichever call site got
  there — it checks `DEVPILOT_REVIEWER_REPLAY_ACTIVE` in the environment as well
  as script scope, so the refusal survives being loaded into a module, a thread
  job or a child process, where a script-scope flag would be invisible.

`DEVPILOT_REVIEWER_REPLAY_ACTIVE` is set by the reviewer, for the reviewer. Any
non-empty value means replay, including `0` and `false`, because a safety guard
is the wrong place to parse intent; assigning `""` deletes the variable in
PowerShell, so removal is the only way to express "off". The reviewer clears it
at startup before anything can read it and sets it only on the replay path, so a
leftover from an earlier replay in the same shell cannot silently disable the
live fallback in a later live run — and if one is somehow present anyway, the
refusal says the variable is stale rather than claiming a replay is happening.

Every replay artifact records what actually served source:
`sourceTransportMode: snapshotLegacy`, `capabilityProbeSuppressed`, and
`azCliFallbackSuppressed` when config had enabled the live fallback. The preview
says the same in prose, because a console warning is gone by the time anyone
reads the file.

## The snapshot

A snapshot is a directory named as a single child of an explicit replay root:

```
<replay root>/
  <snapshot name>/
    manifest.json
    payloads/...
```

`manifest.json` is strict: exact keys, exact types, code-defined caps (4096
resources, 24 MB per payload, 64 MB in total). It records

- `binding` - organization, project, repository id, pull request id, source and
  target commit, and the change-set hash;
- `bindings` - the config, script and prompt hashes and the model list the
  capture ran under;
- `resources[]` - for each recorded read, the tool, the exact arguments, the
  SHA-256 of the canonical `{name, arguments}` that is its lookup key, and the
  payload file with its own hash and byte length;
- `manifestDigest` - a canonical digest over everything above.

Every payload is the exact JSON-RPC response line the read returned.

### What the digest does and does not prove

`manifestDigest` is unkeyed. It proves the manifest still describes its own
payloads - it catches corruption, a partial edit, and a recorder that disagrees
with this reader. It does **not** prove the snapshot was not edited, because
anyone who edits one can recompute it.

Binding a run to a snapshot an operator actually vouched for is the job of
`-ReplayManifestDigest`, which the reviewer requires. Print it once when the
snapshot is made, keep it where the snapshot is not, and pass it on every run.

### Snapshot input is treated as hostile

- The snapshot name must be a single path-free name; `..`, separators, drive
  letters and alternate data streams are refused.
- Every payload path must be a plain relative path, and its resolved location
  must still be strictly inside the snapshot after the filesystem has applied
  its own casing and short-name normalization.
- Any component that is a reparse point - a symlink or a junction - is refused.
  Hard links are deliberately not chased: a hard link can only ever supply the
  exact bytes the manifest already pins by SHA-256.
- Payloads are read and hashed once at load and held in memory, so nothing on
  disk can change under a run, and re-hashed at every serve.
- Duplicate lookup keys are refused: a snapshot must answer each request one way.

### Determinism

Lookup keys and the manifest digest are computed from an ordinally-sorted
canonical JSON with explicit string escaping. Culture-sensitive ordering would
make a snapshot captured on one host fail to load on another; delegating
escaping to the host serializer would make the digest a function of the
PowerShell build. Non-integral numbers and date values are refused rather than
rendered ambiguously - PowerShell's JSON reader turns extended-format ISO-8601
strings into `DateTime`, which is why `capturedUtc` uses the basic
`yyyyMMddTHHmmssZ` form that stays a string on both sides.

A replay preview prints two digests:

- **replay input digest** - over what the wrapper computed from the snapshot
  alone (the source-coverage record and the tool grant). Two replays of one
  snapshot **must** produce the same value; a difference is a determinism defect
  in this toolkit.
- **replay outcome digest** - over the wrapper's normalized decisions: the
  sorted anchors and severities of the candidates it would post, the counts and
  the recommended vote. Comment prose is excluded, so two models that say the
  same thing differently agree. The set of anchors is still downstream of a live
  model, so a difference here is a real semantic difference and is reported as
  one rather than smoothed over.

## Making a snapshot

Capture and sealing are separate on purpose. Capture is host-specific and
credentialed; sealing is pure, so it can be tested, reviewed and run anywhere.

`tools/Save-AgentReplaySnapshot.ps1` does the sealing. It takes payload files an
operator has already captured plus a recipe naming the tool and arguments each
one answers:

```json
[
  {
    "tool": "repo_pull_request",
    "arguments": { "action": "get", "project": "P", "repositoryId": "...", "pullRequestId": 1 },
    "payloadFile": "payloads/pr-get.json"
  }
]
```

It refuses to seal a recorded write, computes every hash and the manifest
digest, and then loads what it just wrote to prove the result is a snapshot this
build accepts.

`src/Agents/reviewer/testdata/replay-v1/synthetic-pr` is a committed synthetic
snapshot - invented organization, invented repository, a synthetic GUID and two
made-up files - that exercises the mode end to end without any real repository
content. `tools/Test-ReplaySnapshot.ps1` drives it.

## Running a replay

```pwsh
./src/Agents/reviewer/Start-ReviewerAgent.ps1 `
    -ConfigFile <config> -OperatorAlias <alias> -Once `
    -PullRequestId <the pull request the snapshot was captured for> `
    -Model claude-opus-5 -SecondPassModel gpt-5.6-sol `
    -ReplayRoot <replay root> -ReplaySnapshotName <snapshot> `
    -ReplayManifestDigest <digest>
```

All three replay parameters are required together. `-PullRequestId` is required
and must match the snapshot's binding: the recorded pull-request list is a
moment in that repository's history, and letting it drive candidate selection
would quietly make the run about a different pull request than the operator
pinned. The snapshot's organization, project and repository must match the
running configuration, or the run refuses rather than producing a
self-consistent artifact stamped with the wrong identity.

`-DryRun` cannot be combined with replay: the self-checks run against their own
fixtures and never open a session.

A snapshot captured under a different config, script or prompt build still
loads, with a warning - a transport change since capture can ask for reads the
snapshot does not carry, and that fails closed with the exact request named.

## One run is not a result

A replay is deterministic in its inputs and not in its model. The same snapshot,
replayed twice, can produce two different readings of the same rule - different
wording always, and sometimes a different verdict. Either run, read on its own,
looks exactly like a result.

So a single replay artifact says so about itself. It carries a residual risk
naming the run as unreconciled, the preview says the same in its header, and the
sealed manifest sets `replay.reconciled = false` with `runsReconciled = 1`.
Nothing about that is advisory: a consumer that wants a stable status has to go
and get one.

`tools/Compare-ReviewerReplayRuns.ps1` is how. Give it the sealed specialist
artifacts from two or more runs of the same snapshot:

```pwsh
./tools/Compare-ReviewerReplayRuns.ps1 `
    -ArtifactPath run1.json, run2.json `
    -KeyPath <state>/artifact-signing.key `
    -OutputDirectory <out> -FailOnDisagreement
```

It refuses to compare runs that are not repetitions of one question. The binding
- pull request, source commit, config, script, specialist library, prompt, both
plans, model, and the enumerated construct table - must be identical, or the
runs are about different code. The replay nonces must all be *different*, or the
"two runs" are one run submitted twice, which is how a single favourable
observation would otherwise launder itself into a stable result.

The semantic form is reconciliation artifact version 2; version 1 remains a
separate legacy schema and is never interpreted as carrying semantic identity.
Then version 2 collapses runs:

- A rule every run read the same way keeps that reading, along with the anchors
  they agreed on.
- A rule the runs read differently becomes `unknown`, and both readings are
  printed. Agreeing on the word while naming different anchors counts as
  disagreement - `violation at mi14` and `violation at mi15` are two findings
  wearing one status.
- A rule some run never accounted for at all is `unknown`.
- Candidate agreement uses `reviewer.semantic-candidate` version 2, not comment
  text. Its sealed canonical payload binds the authoritative rule id and digest,
  normalized file path, anchor kind/line and exact construct spans, issue and
  impact class, severity, confidence, sibling status, deterministic fact and
  violation sets, and structured remediation action/scope/targets/follow-up
  requirement. Candidate/model ids and free-form prose are excluded.
- When those semantics agree, the result is
  `semanticAgreementTextWithheld`: it is one stable evaluation finding, but its
  `comment` is empty and no model wording is selected. Every raw presentation
  variant, including its confidence and sibling status, remains in deterministic nonce/digest order under
  `presentationVariants` until an independently verified renderer can produce
  canonical text.
- A different rule digest, construct/span, issue or impact class, severity,
  confidence, sibling status,
  deterministic evidence/violation set, or remediation identity is a different
  candidate and remains withheld. Missing fields, incompatible semantic schema
  versions, contradictory follow-up fields, unknown remediation targets, and
  malformed identities are withheld rather than inferred.
- Anything else is withheld with the runs that disagreed named.

There is no majority vote and no tie-break. Two runs out of three is not a
result. The reconciliation never picks the interesting reading, the common one,
or the first one - disagreement resolves to `unknown` and stays visible.
Semantic agreement does not add delivery authority: the reconciliation remains
non-promotable, replay-only evaluation output, and canonical presentation text
is deliberately absent.

The reconciliation is sealed under the same derived replay key as the runs that
fed it, so it verifies only there and never against the promotion path. A
live-run artifact cannot be fed to it at all: live artifacts are sealed under
the raw key, and the reconciler reads only the replay domain.
The tool takes the sealed artifact and the signing key from each run. Repeats
belong in separate state directories - that is what keeps them independent -
and each of those mints its own key, so pass one `-KeyPath` per run in the same
order, or a single one if the runs shared a state directory.

Runs are lined up by `ruleRef` rather than by rule id, because one source can
legitimately be transported under two refs and keying on the id would turn that
into a phantom duplicate. The ref is a position in the request list, which is
safe here precisely because the binding already pins the config and both plans -
and the rule id and hash are compared per row anyway, so a run whose `rs2` is
about a different rule than the other's `rs2` disagrees rather than being
quietly lined up.
### Declaring the run set before you look

An operator who picks which runs to compare after seeing their results has not
reconciled anything; they have chosen an answer. So the set is declared and
sealed first:

```pwsh
./tools/Compare-ReviewerReplayRuns.ps1 -DeclareRunSet `
    -SnapshotName pr12345 -SnapshotManifestDigest <digest> `
    -PlannedRunCount 4 -Purpose "calibration at head abc1234" `
    -KeyPath <state>/artifact-signing.key -OutputDirectory <out>
```

Then run the replays, and reconcile against the declaration:

```pwsh
./tools/Compare-ReviewerReplayRuns.ps1 `
    -ArtifactPath run1.json, run2.json, run3.json, run4.json `
    -KeyPath k1, k2, k3, k4 `
    -RunSetPath <out>/runset-<id>.json -RunSetKeyPath <out>/artifact-signing.key `
    -OutputDirectory <out> -FailOnDisagreement
```

The comparison refuses an artifact that replayed a different snapshot, and
refuses a set that is short or topped up. The declaration is sealed before any
run exists, so it normally has its own key; pass `-RunSetKeyPath` unless it
shares a state directory with the first run.

**Do not edit the reviewer while a qualification set is in flight.** The
binding covers the script and the specialist library, so a run that finishes
after an edit binds differently and the set is spoiled - which the tool will
tell you, having refused to reconcile it.