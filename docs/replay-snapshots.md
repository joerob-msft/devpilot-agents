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

Every repository read in this toolkit goes through `Send-AgentMcpRequest`. A
replay session is served there, which is why the layers above it need no
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
