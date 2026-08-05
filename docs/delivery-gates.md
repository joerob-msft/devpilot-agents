# Delivery gates (layer 6)

Delivery gates are an optional, fail-closed layer over the sealed
cross-verification preview (see [Cross-verification previews](cross-verification.md)).
They let a small, cryptographically bound set of *already independently
verified* findings reach a PR unattended - as comments, as suggestions, or as
an approval vote - without changing discovery, specialist, clustering, or
verifier behavior, and without ever accepting a raw delivery or verification
artifact as a gate artifact.

Everything in this document describes what the code does. Where a guarantee
is weaker than it sounds, that is said plainly rather than implied away.

## Why this is a separate layer, not a mode of delivery

Raw delivery (comments, summary, vote) and cross-verification (§
[cross-verification.md](cross-verification.md)) already exist and are
untouched by this layer. The gate reads their SEALED, already-written
artifacts - the verification input preview and verification decision preview
- and never mutates them. `DeliveryGates.ps1` is a pure, standalone library
(no MCP, no network, no provider call, no write of its own; enforced by a
`-DryRun` self-check that source-scans the file). `Start-ReviewerAgent.ps1` is
the only place that performs a gate-related read or write, and it does so
through its own state files, its own HMAC domain, and its own artifact kind.

**Ordering.** The existing tail of a review cycle - discovery, specialist,
cross-verification, delivery, state, metadata, exit code - is finalized first,
byte-identical to before this layer existed. The gate's entry point,
`Invoke-ReviewerGateForPullRequest`, is called strictly after that tail, at
every one of `Invoke-ReviewerPullRequest`'s three return points (both failure
paths and the success path), and its very first statement returns immediately,
having read or written nothing, when the effective policy's `mode` is `"off"`
(the default). A `-DryRun` self-check proves this ordering by scanning the
wrapper's own source for every paired verification/gate call and by invoking
the gate function directly with `mode = "off"` and asserting zero filesystem
writes.

This is a deliberate, narrower alternative to reordering specialist and
verification to run *before* raw delivery, which an earlier design review
raised as one way to let the gate see fresher state. Reordering the existing
tail would let the gate's presence perturb the raw delivery path itself -
changing when `Invoke-ReviewerDeliveryStillValid`-style aborts can occur, for
a benefit the gate does not need. The gate never influences raw delivery,
state, or exit code, and it does its own two rounds of live revalidation
immediately before any gate write (below); running strictly after achieves a
*stronger* invariant than "unchanged only when gates are off" - the call
sequence up to and including cross-verification is identical *regardless of
gate mode*.

## Typed delivery authorization: raw stays PreviewOnly, the gate is the sole VerifiedMultiPass writer

An independent multi-pass union (`-SecondPassModel`) is discovery-only until a
code-defined `VerifiedMultiPass` authorization exists. **Raw two-pass delivery
and raw `-PromotePreview` never obtain one and stay `PreviewOnly` permanently**
- this layer does not reorder, weaken, or add an escape hatch to that rule.
Single-pass raw delivery (`SinglePass`) is completely unaffected.

This layer is the sole, code-defined producer of `VerifiedMultiPass`:
`New-ReviewerVerifiedMultiPassAuthorization` in `Start-ReviewerAgent.ps1`,
which is the *only* place in the script that constructs one. It is used to
authorize exactly four write paths, and nothing else:

1. gate comment/suggestion writes (`Invoke-ReviewerGateDelivery`);
2. a gate replay of an incomplete delivery (`Invoke-ReviewerGateReplay`);
3. `-PromoteVerifiedPreview` (`Invoke-ReviewerPromoteVerifiedPreview`);
4. the gate's own independent approval vote (`Invoke-ReviewerGateDelivery`'s
   approval branch), minted separately from comments, after they are
   confirmed complete.

The mint re-derives every input itself rather than trusting a caller-built
object: it takes a **decision artifact path** (never a decision object),
re-verifies it through `Read-ReviewerGateDecision` (HMAC domain + kind +
binding + expiry), performs its **own** dedicated, fresh, isolated-session
revalidation, and requires - among other things - that the *sealed* decision
itself (never the live `-SecondPassModel`/config) records exactly two
completed passes with the literal `claude-opus-5`/`gpt-5.6-sol` pair
(`passesRequested`/`generalistPassModels`, part of the sealed binding). Policy,
qualification, and CLI switches can only **narrow** what the mint is willing
to grant - never supply positive evidence on their own - and gate mode `"off"`
(the default) always refuses.

Every grant this mint returns is bound, at mint time, to one exact
purpose/PR/source-commit/coverage-key-set and stamped with a mint time; the
assertion immediately before each write re-checks that binding *and* a
code-defined maximum grant age (120 seconds), so a grant cannot be reused
across PRs, commits, purposes, or a wider write set than it was minted for -
live narrowing after the mint (e.g. an anchor moving out of the change set)
causes a fresh, narrower mint rather than reusing the wider one. The grant is
never written to a state file, artifact, or log; only its `Kind`/`Reason`
scalars ever are.

## Enablement: three authorities, and a repository can only subtract

No unattended gate behavior is reachable unless **all three** of the
following agree, every run:

1. **An out-of-repo policy file** at a `mode` other than `"off"` - either
   `-GatePolicyFile <path>`, or an implicit `<StateDir>/gate-policy.json` if
   no explicit path is given. Either way, the resolved path is checked to
   fall **outside** the reviewed repository's working tree
   (`Test-ReviewerGatePathOutsideRepository`); a policy file that resolves
   *inside* the repository is treated as if it were absent; not
   parsed for content. A clone parked on a PR branch cannot smuggle
   enablement into its own review.
2. **The matching CLI switch** - `-EnableVerifiedCommentGate`,
   `-EnableVerifiedSuggestionGate`, and/or `-EnableVerifiedApprovalGate` - for
   the capability being exercised.
3. **A verified qualification artifact** - `-GateQualificationFile <path>`,
   also required to resolve outside the repository, signed with this
   deployment's own artifact-signing key, unexpired, and meeting every
   code-defined precision/recall/sample/false-approval floor for the exact
   (pack, severity) or approval aspect in question.

Missing, unreadable, malformed, or in-repo policy/qualification all fail
closed to the shipped all-off default
(`src/Agents/reviewer/gates/v1/policy.json`) - a corrupt or absent optional
file degrades this layer, never the underlying reviewer.

**The repository's own config can only narrow.** `config.review.deliveryGates`
is an optional sibling of `config.review` with exactly one power:
`disabled: true` forces every gate mode to `"off"` regardless of what any
policy file or CLI switch says. There is no `enabled` key, and none of the
other two authorities above are things a repository's checked-in config or a
pull request's content can ever set. This is checked last, specifically so it
can override an otherwise-valid enabling policy - the local/config kill switch
is a ceiling PR content cannot lift, not a default PR content could flip.

```json
"review": {
  "deliveryGates": {
    "disabled": false
  }
}
```

## Code-defined ceilings and floors

A policy file may narrow a cap, or raise a floor, and nothing else. The
direction is per key (`ConvertTo-ReviewerGateEffectivePolicy`):

| Kind | Keys | Effective value |
|---|---|---|
| Cap (policy may only lower) | `maxCommentsPerRun`, `maxSuggestionsPerRun`, `maxDecisionAgeSeconds`, `maxQualificationAgeDays`, `maxApprovalFalsePositives` | `Min(codeCeiling, policyValue)` |
| Floor (policy may only raise) | `minPrecisionLowerBound95`, `minRecallLowerBound95`, `minCommentSampleCount`, `minApprovalSampleCount` | `Max(codeFloor, policyValue)` |

Code ceilings/floors today: `maxCommentsPerRun=3`, `maxSuggestionsPerRun=2`,
`maxDecisionAgeSeconds=1800`, `maxQualificationAgeDays=90`,
`minPrecisionLowerBound95=0.90`, `minRecallLowerBound95=0.50`,
`minCommentSampleCount=100`, `minApprovalSampleCount=150`,
`maxApprovalFalsePositives=0`, plus a hard cap of 32 packs and 64 required
check names, and a 1 MiB artifact size ceiling.

**`$script:ReviewerGateMaxSupersededRefreshes` (`2`) is a stricter, separate
category: not one of the cap keys above, and not policy-adjustable at all.**
Every key in the table is something a policy file can narrow further; this
one is never read from `gate-policy.json` in any form, narrowing included -
see "Gate-delivery state machine" below for what it bounds and why.

**`maxDecisionAgeSeconds` must exceed the reviewer's own cycle interval.**
The shipped `gates/v1/policy.json` sets this to the same `1800` seconds as
the code ceiling - well above `Start-ReviewerAgent.ps1 -IntervalSeconds`'s
own default of `900` seconds. A decision that could expire before the
*next* cycle even runs would make an incomplete delivery's replay window
degenerate: `Invoke-ReviewerGateReplay` would find every pending delivery
already expired and close it (see "Gate-delivery state machine" below)
before a normal retry ever had a real chance. Any deployment that lowers
`-IntervalSeconds` well below its default should raise this margin
accordingly (subject to the `1800`-second code ceiling).

**Critical severity is hard-overridden, unconditionally**, both by omission
from the unattended-severity ceiling and by an explicit override in
`ConvertTo-ReviewerGateEffectivePolicy`: no policy value can ever make an
unattended critical comment reachable. A false critical is the most expensive
false positive this agent can produce; only a human reading a
human-promotable preview ever sees one.

**Suggestions are separately gated.** `unattendedComment`-severity findings
becoming reachable does not, by itself, make suggestions reachable: the
suggestion path additionally requires `mode = "unattendedCommentAndSuggestion"`
*and* `-EnableVerifiedSuggestionGate`. Neither alone is sufficient.

## Modes

`off` → `shadow` → `preview` → `humanPromote` → `unattendedComment` →
`unattendedCommentAndSuggestion` → `approvalVote`, each one strictly a
superset of what the previous mode writes:

- **`off`** (default): nothing runs.
- **`shadow`**: seals a gate-decision artifact and a JSONL log entry only.
  Nothing human-readable, nothing posted.
- **`preview`**: `shadow`, plus a Markdown rendering of the decision a human
  can read.
- **`humanPromote`**: `preview`, plus the decision's `humanPromotableComments`
  become eligible for a human to publish with `-PromoteVerifiedPreview`
  (below). Still nothing is posted automatically.
- **`unattendedComment`**: important-severity comments the decision marks
  `unattendedCommentOk` are posted automatically, subject to
  `-EnableVerifiedCommentGate` and `maxCommentsPerRun`.
- **`unattendedCommentAndSuggestion`**: adds suggestion-severity comments,
  subject to `-EnableVerifiedSuggestionGate` and `maxSuggestionsPerRun`.
- **`approvalVote`**: adds an unattended `Approved` vote, subject to
  `-EnableVerifiedApprovalGate`, `policy.approval.enabled`, and every
  independent precondition below.

## What a gate decision seals

`New-ReviewerGateDecision` (pure; the caller supplies every already-live
value) builds one `reviewer-gate-decision` manifest binding: PR id,
repository/organization/project identity, source and target commit,
change-set digest, the verification decision/input SHA-256s, convention-plan
and fact-plan SHA-256s, the specialist artifact SHA-256, the pack policy,
config, script, gate-library, gate-policy, and qualification SHA-256s, the
verification library/prompt/policy/schema SHA-256s, a thread-set digest, and
(reserved for a future policy/checks snapshot binding) checks/policy snapshot
placeholders. Every candidate is carried with its own reason codes for both
the unattended and human-promoted eligibility questions - there is no
candidate the decision is silent about.

The same manifest also seals approval-specific gate-owned accounting:
`gateHumanPromotableCount`, `gateImportantOrHigherCount`, and the sorted
`gateImportantOrHigherKeys`. These values are mechanically derived from the
sealed candidate entries, not supplied by a model or config. They let the
approval path prove that specialist/gate findings did not disappear behind
the independent raw generalist vote.

The manifest is sealed with `Save-ReviewerGateArtifact`, which canonicalizes it
with the same strict, duplicate-key/non-finite-number-rejecting canonicalizer
cross-verification uses, then signs it with an HMAC key derived from this
deployment's artifact-signing master key under the `"decision"` domain label
`devpilot.reviewer.gate.decision.v1`. A qualification artifact is signed
under a **separate** derived key (`devpilot.reviewer.gate.qualification.v1`).
Both are separate again from cross-verification's `input`/`preview` domains
and from raw delivery's un-derived master key. A decision can never be read
back as a qualification, a qualification can never verify as a decision, and
neither can ever verify as a raw delivery or verification-preview artifact -
proven by dedicated tamper/cross-domain tests in both
`tools/Test-DeliveryGates.ps1` and the wrapper's own `-DryRun` self-checks.

**What a signature proves, and what it does not.** A valid signature proves
the artifact was not edited after this deployment's own key sealed it, and
that whoever holds that key sealed it - the same guarantee documented for
raw delivery artifacts. It does not, and cannot, prove the person who ran the
qualification corpus was honest, or that the numbers in it are real. That
trust boundary is organizational: who is allowed to run
`tools/New-ReviewerGateQualification.ps1` and publish its output where a
`-GateQualificationFile` can find it. No cryptography in this repository
closes that gap, and this document does not pretend otherwise.

## Candidate eligibility (comments and suggestions)

`Test-ReviewerGateCandidateEligible` requires, per candidate:

- the candidate is `verified` (not `duplicate`, `unsupported`,
  `wrongSeverity`-corrected-away, or `needsHuman`) in the sealed verification
  decision;
- its anchor still falls inside the current change set - a candidate with no
  file anchor at all (a PR-level finding) is **always** ineligible for this
  layer (`anchorNotInChangeSet`), deliberately: without an anchor there is
  nothing to re-check against the current change set or an existing thread.
  Raw delivery's own, separate PR-level acceptance is unaffected;
- source commit, target commit, and change-set digest are all still what the
  decision was sealed against;
- no existing PR thread or prior-agent record already covers it
  (thread/prior-agent dedupe);
- the deterministic facts and authoritative-source evidence it cites are
  still current;
- for a clustered candidate, sibling members are still current;
- its (pack, severity) combination is enabled in the effective policy, for
  the purpose being asked (`unattendedComment` vs. `humanPromotedComment`
  have independent per-pack, per-severity flags);
- for an unattended purpose only, its (pack, severity) qualification scope
  meets the effective precision/recall/sample floors
  (`Test-ReviewerGateQualificationSatisfies`).

`Test-ReviewerGateVerificationComplete` additionally requires, at the *run*
level: the verification decision itself is not degraded, every candidate the
decision withheld has a reason on the closed "safe" list
(`duplicateExistingThread`, `duplicatePriorAgent`, `duplicateCandidate`,
`unsupported`) rather than a reason meaning unexplored territory (a bounded
run cap like `candidateLimit`/`clusterLimit` closes the run), and no candidate
anywhere is `needsHuman`. A run that fails this accounting still lets already
-eligible candidates be individually posted at `unattendedComment`/
`unattendedCommentAndSuggestion` (a single withheld/degraded candidate does
not silence everything this run *did* verify) but unconditionally closes the
approval gate - approval is the one place where "we are not sure we saw
everything" must mean no.

## Promotion is monotonic: remove-only, never add or reshape

`Invoke-ReviewerPromoteVerifiedPreview` (dispatched by
`-PromoteVerifiedPreview <path>`) publishes a human-selected subset of a
sealed decision's `humanPromotableComments`, using the exact same comment
formatter (`Format-ReviewerFindingComment`) every other comment this agent
posts uses. `Select-ReviewerGateSubset`/`Get-ReviewerGateManifestKey` enforce
that the published set can only be the sealed set or a subset of it: nothing
can be added, reworded, relocated, or have its severity raised relative to
what was sealed. It never casts a vote - approval only ever happens through
the fully unattended `approvalVote` policy mode, never through a
human-promoted artifact, and this is checked twice: once structurally (there
is no vote parameter on this dispatch path) and once by a `-DryRun`
self-check asserting the gate's allowed-vote set is the closed singleton
`{"Approved"}`.

**Cross-promotion is rejected both ways.** The existing, raw
`-PromotePreview` now also rejects any artifact bearing a
`"reviewer-gate-decision"` kind - a sealed gate decision can never be
laundered through the raw delivery promotion path, which has no concept of
gate eligibility at all. Symmetrically, `-PromoteVerifiedPreview` rejects a
raw delivery manifest, a `verification-input-preview`, and a
`verification-decision-preview` - only the exact `reviewer-gate-decision`
kind and artifact version verify. Both directions are pinned by `-DryRun`
self-checks.

**A decision's bindings are re-verified fatally, before any write.** Sealing
a decision does not make it permanently trustworthy: the script, config, gate
policy, gate library, verification library/prompt/policy/schema,
convention-pack policy, and (when relevant) qualification could all have
changed since. `Test-ReviewerGateDecisionBinding` compares every one of those
recorded hashes - plus repository/organization/project - against the CURRENT
live values, and `-PromoteVerifiedPreview` calls it immediately after reading
the decision, before opening any session or posting anything. A mismatch
throws with the specific reason code (`scriptShaMismatch`,
`configShaMismatch`, `policyShaMismatch`, `gateLibraryShaMismatch`,
`qualificationShaMismatch`, or `decisionBindingMismatch`) and nothing is
published. There is no flag to skip this check.

**A revoked qualification always closes a decision that depended on one.**
The live qualification hash bound for comparison is set unconditionally -
either the currently resolving qualification's own hash, or 64 zero
characters when none currently resolves (missing file, invalid contents, or
the `-GateQualificationFile` argument itself dropped since the decision was
sealed) - never skipped just because nothing is currently available to
compare against. `Test-ReviewerGateDecisionBinding` special-cases only the
**sealed** side of this one key: a sealed value of all-zero (this decision
never depended on any qualification at all, e.g. `humanPromote` mode) always
matches regardless of what is live, so a qualification appearing later can
never regress a decision that never needed one. Any sealed **non-zero**
value, however, is compared unconditionally against whatever the live value
is - including all-zero - so a qualification that resolved when the decision
was sealed but has since been removed, tampered with, or lost its argument
reliably closes with `qualificationShaMismatch`, both on replay and on
`-PromoteVerifiedPreview`.

## Approval: independent AND, strictly stronger than the raw vote gate

`Test-ReviewerGateApproval` is a pure function of booleans the caller
resolves from live reads and the sealed decision; every one of the following
must hold, or the corresponding reason code is added and the vote does not
happen. There is no majority, no "good enough," and no early exit that skips
a later check:

- `mode = "approvalVote"` and `policy.approval.enabled`;
- the reviewed PR is on a **GitHub** repository (`ProviderIsGitHub`) - see
  "A residual limitation, stated plainly" below;
- the sealed run accounting is OK (verification not degraded, no unsafe
  withheld reason, no `needsHuman` anywhere);
- **both** configured generalist models completed **and** both recommended
  `approve` on their raw passes (`GeneralistPairComplete`,
  `GeneralistBothApprove`) - read from `$Bound.RawRecommendedVote`/
  `RawCounts`/`RawPassesComplete`, the same values the *existing*,
  unmodified `Test-ReviewerShouldVote` raw vote gate is independently asked
  about (`RawGateApproves`) - the gate does not invent a second opinion, it
  requires the *existing* vote gate to *also* say approve, on the *raw*
  merged findings, completely independently of anything the gate library
  computed;
- convention specialist discovery is either not enabled for this run or
  completed (not degraded);
- the sealed gate decision contains **zero** human-promotable findings and
  **zero** important-or-critical gate-owned findings, and the second
  revalidation confirms zero important-or-critical gate findings already
  present on the PR (`gateFindingsUndelivered` otherwise). This is deliberately
  conservative: a verified specialist finding can veto approval but can never
  help grant it. In particular, the agent cannot post an important finding and
  approve in the same run;
- required checks, if `policy.approval.requireChecks`, are positively known
  and all green (`Get-AgentProviderRequiredChecksSnapshot`) - unknown or
  absent checks close the gate exactly like a failing one;
- the branch's review-dismissal policy, if
  `policy.approval.requireDismissStaleReviews`, is positively known to
  dismiss stale reviews on a new push
  (`Get-AgentProviderReviewDismissalPolicy`) - unknown closes the gate;
- if `policy.requirePriorRunEligibility`, this exact eligibility fingerprint
  (source commit + change-set digest + candidate count + decision hash +
  gate-policy hash) was already recorded on a **previous** run, not first
  discovered on this one (`Get-ReviewerGateEligibilityFingerprint`) - an
  approval cannot be the very first time this state was ever observed;
- if `policy.requireCanaryConfirmation`, an operator-provided
  `-GateCanaryTokenFile` contains a line naming this exact PR and source
  commit (below) - never satisfied by a CLI switch alone;
- the source commit is unchanged since both the decision was sealed and a
  **second**, immediately-preceding revalidation (below);
- every authoritative source the decision cited is still readable and
  unchanged - **today this always closes the gate** rather than pass an
  unverified claim; see "A residual limitation, stated plainly" below;
- this exact source commit has not already been voted on;
- a qualification artifact is present and its `approval` aspect meets the
  effective sample/recall floors and has `falseApprovalCount` at or under
  the effective ceiling (0, by code default, unconditionally).

**Specialist can only veto or degrade approval, never grant it on its own** -
`SpecialistOkForApproval` participates only as one more required-true AND
term; there is no path where specialist output alone satisfies approval.

## Two independent revalidation sessions, never the cycle's own

Both before writing comments and immediately before casting a vote,
`Invoke-ReviewerGateRevalidation` opens a **fresh**, isolated MCP session via
the same `Invoke-ReviewerConventionSession` helper convention-pack selection
already uses (never the cycle's own long-lived session), and re-reads: PR
status/draft/source-commit, the change set (pinned twice, digest-compared),
existing PR threads, and, on GitHub, branch review-dismissal policy and
required-check state. The **first** revalidation gates comment/suggestion
writing. The **second**, run again immediately before the vote call, is what
catches a source push that landed while comments were being written - this
is what "source-push simulation closes the vote" means in practice: any
commit movement between the two revalidations, or between either
revalidation and the sealed decision, fails the vote closed
(`sourceCommitMoved`).

The second mint also re-derives the important-or-higher gate keys confirmed in
the freshly read thread set. Its typed approval authorization is bound to a
digest of that exact confirmed set plus the decision's sealed
human-promotable/important accounting. A grant minted for a zero-finding state
cannot be reused after a gate finding appears.

## Confirm-then-vote, never vote after a comment failure

`Invoke-ReviewerGateDelivery` writes comments first and re-reads the PR's own
threads to independently confirm each one landed - the same
"confirm by re-read, not by trusting a response" discipline the raw delivery
path already uses (extracted into the pure, independently-tested
`Test-ReviewerGateWriteConfirmed`, so "some comments landed, some did not" is
exercised without a live MCP session). If any requested comment cannot be
confirmed, the gate records a **separate**, gate-only pending-delivery record
(`gate-delivery.json`, entirely distinct from the raw delivery's
`reviewed.json`/`attempts.json`) and returns without ever attempting the
vote call - a partial comment failure can never be followed by a vote on this
run. This function is also the one place every caller's request is
independently re-derived against the CURRENT effective policy mode and CLI
switches (`Get-ReviewerGateWritesCurrentlyRequested`) and against the
decision's own expiry (`Test-ReviewerGateDecisionExpired`) - belt-and-braces,
so a caller that ever computed a stale or wrong request still cannot cause a
write beyond what is currently authorized.

Even when every requested comment was confirmed, approval remains closed if
the sealed decision contains any human-promotable or important-or-critical
gate-owned finding. Confirmation is not treated as resolution: posting an
important finding does not make it compatible with approval.

**A replay never trusts its own persisted request.** On a later cycle, if raw
delivery is already fully satisfied at this same commit (so the cycle would
normally skip the PR entirely) but a gate delivery record still owes
something, the cycle instead calls `Invoke-ReviewerGateReplay`. Before
touching anything, it fatally re-verifies the sealed decision's bindings
(`Test-ReviewerGateDecisionBinding`, the same check `-PromoteVerifiedPreview`
uses) and its expiry (`Test-ReviewerGateDecisionExpired`); either failure
closes the pending record for good (`pendingReplay = false`, `superseded =
true` - see "Gate-delivery state machine" below) rather than retrying a
decision that can never become valid again. It then re-derives what is
CURRENTLY authorized the same way a fresh decision would
(`Get-ReviewerGateWritesCurrentlyRequested`) and intersects that with what
was originally requested - the persisted request is an upper bound, never a
substitute for asking again, so a CLI switch removed or a policy mode
downgraded since the original attempt narrows the replay to nothing rather
than outliving the authority that produced it. Only once all of this passes
does it retry **exactly what the sealed decision says is still missing** -
it never re-runs the model, never re-derives eligibility, and never re-seals
a new decision.

**A gate capability enabled after the fact still gets its first chance.**
Because raw delivery and the gate track completion independently, a commit
that was already raw-previewed under an OLDER configuration (before a gate
capability was turned on) would otherwise be skipped forever by the raw
"already reviewed" check, with no gate-delivery record to trigger a replay
either - a newly-enabled capability could never run against that commit at
all. `Test-ReviewerGateDecisionEverAttempted` tells apart "gate delivery has
already run at this exact commit" from "it has never had a chance to," and
the cycle loop falls through to a full review instead of skipping when the
latter is true and a gate write is currently possible. That fresh review's
own raw findings are never a second raw delivery: `Invoke-ReviewerPullRequest`
is told, by the cycle loop's OWN pre-existing "already reviewed" check (made
before any state mutation), that raw already owes nothing further here, and
substitutes the pure `Get-ReviewerGateRefreshStandInDelivery` for a real
`Invoke-ReviewerDelivery` call - carrying the prior run's comment/summary/vote
outcomes through unchanged instead of posting or voting again, while the
gate itself still sees this fresh run's genuinely current findings for its
own decision. Separately, a raw pending-delivery plan interrupted mid-write
under OLDER write switches cannot be resurrected by this same fall-through
either: `Test-ReviewerRawPendingPlanShouldReplay` refuses to route a still-
existing `deliveryPending=$true` plan into `Invoke-ReviewerPromotion` once
raw delivery is satisfied under TODAY's switches (including vacuously, when
every raw switch is off) - a stale plan from before the operator turned raw
writes off entirely must never post/vote under raw authority again purely
because the gate needed a refresh.

**A gate refresh never claims or overwrites `reviewed.json`'s raw
delivery-plan pointer, either.** The crash-safety placeholder write and the
final persist step both skip entirely when raw delivery is already
satisfied: `Get-ReviewerPersistedReviewRecord` returns `$null` (meaning
"leave `reviewed.json` untouched, do not call `Set-JsonState` at all") the
moment `RawDeliveryAlreadySatisfied` is true, before computing anything from
this cycle's fresh preview. Without this, a fresh gate-refresh model run's
own nonce would make `PriorAppliesToThisReview` false in
`Merge-ReviewerCapabilityFlag`/`Get-ReviewerPlanCapabilities`, which would
silently reset `commentsDelivered`/`summaryDelivered`/`voteResolved` to
`$false` and recompute `pendingCapabilities`/`artifactPath`/`reviewDigest`
from a review that never delivered anything at all - destroying a still-open
raw plan's own artifactPath and losing track of exactly which finding still
needs to post, permanently, the moment a gate capability's first chance
happened to coincide with an interrupted raw delivery. The fresh preview
this cycle still writes to disk remains available for a human to read and
for the gate's own tail to consume; only `reviewed.json`'s raw delivery-plan
POINTER is preserved verbatim, so a later cycle with raw write switches on
resolves `Get-ReviewerPendingDeliveryPlan` to the ORIGINAL sealed artifact
and replays it via `Invoke-ReviewerPromotion`, never a fresh raw model run.

### Gate-delivery state machine

Each PR/commit's record in `gate-delivery.json` settles into exactly one of
four shapes, and the cycle loop's fall-through/skip decision
(`Test-ReviewerGateDecisionEverAttempted`) is what tells them apart:

| State | How it arises | `superseded` | `pendingReplay` | Next cycle |
|---|---|---|---|---|
| Delivered / pending-replay | `Invoke-ReviewerGateForPullRequest` completes normally | `false` | reflects whether comments are confirmed complete | Replayed if still pending; otherwise skipped (genuinely done) |
| **Superseded** | `Invoke-ReviewerGateReplay`'s bindings or expiry check fails before any write, and the supersede budget below is not yet exhausted | `true` | `false` | Counts as **NOT** attempted - exactly one fresh full review seals a current decision |
| **Superseded-budget-exhausted (terminal)** | The same closure, but one more supersede at this exact commit would exceed the hard `$script:ReviewerGateMaxSupersededRefreshes` ceiling | `false` | `false` | Counts as attempted - no further gate processing until a new push (a new source commit) |
| **Faulted** | `Invoke-ReviewerGateForPullRequest`'s outer catch, only when no more-informative record already exists for this same commit | `false` | `false` | Counts as attempted - no further gate processing until a new push (a new source commit) |

Superseded and faulted are deliberately distinguished so that an *expected,
routine* event (a short-lived decision's validity window elapsing, or a
config/script rotation invalidating a stale sealed decision) always gets
exactly one fresh chance, while a *genuine processing fault* (an exception
with no decision usably sealed) does not turn into an unbounded full-model
re-run every single cycle. Neither state is ever silently retried more than
its own rule allows: a superseded record cannot re-supersede itself into an
infinite loop, because the very next cycle's fresh review either succeeds
(sealing a normal, non-superseded record), itself faults (sealing a faulted,
non-superseded record), or gets superseded again - all three of which either
count as attempted or consume one more unit of the hard supersede budget.

**The supersede budget itself is hard, code-defined, and never widened by
policy.** `$script:ReviewerGateMaxSupersededRefreshes` (`2` today) bounds how
many times, in a row, at the exact same commit, a decision can be superseded
before a persistently slow or flaky delivery path is cut off. A
`supersededCount` field on the gate-delivery record is carried forward,
never reset, by every write that stays at the SAME commit - both a fresh
`Invoke-ReviewerGateForPullRequest` success (a new decision superseding the
prior one) and `Invoke-ReviewerGateReplay`'s own supersede closure. It
resets to `0` only when the record's `sourceCommit` changes (a genuine
source push) - `Test-ReviewerGateDecisionEverAttempted` already treats a
different commit as "never attempted" regardless of the old commit's
`supersededCount` or terminal state, so a new push always reopens the gate
with a fresh budget. `Test-ReviewerGateSupersededBudget` is the pure
boundary check; it is never read from `gate-policy.json`, is not one of the
policy-adjustable cap keys, and cannot be widened from a repository.

## The canary token file

A plain text file, one confirmation per line, each line exactly:

```
<pullRequestId>:<sourceCommitFortyHexLowercase>
```

For example, `12345:1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b`. A line is an
exact (case-sensitive, ordinal) match or it is not a confirmation for that
PR/commit. This is deliberately not a CLI switch: a switch would be
"always true" every run, not a considered, per-PR, per-commit act.

## Gate state and artifacts on disk

| Path (under `-StateDir`) | Contents |
|---|---|
| `gate-decisions/` | Sealed `reviewer-gate-decision` artifacts (JSON) and, when rendered, their Markdown previews. |
| `gate-eligibility.json` | Per-PR eligibility fingerprint history, for `requirePriorRunEligibility`. Separate key space from `reviewed.json`. |
| `gate-delivery.json` | Per-PR/commit pending gate-delivery plans (which comments/suggestions/vote still owe a write) and their state ("Gate-delivery state machine" above). Separate key space from `reviewed.json`/`attempts.json`; a raw pending-delivery lookup never reads this file and vice versa. |
| `artifact-signing.key` | Shared with raw delivery and cross-verification: the same per-user, DPAPI-protected (Windows) HMAC master key every domain derives its own key from. |

Resolving `-GateQualificationFile` is lazy and memoized per process
specifically because verifying it requires this signing key, and the key
file is created on first use - `-DryRun` must stay side-effect-free, so
nothing touches it during a dry run.

**`-DryRun`'s gate self-checks never touch any of the paths above.** Rather
than carefully saving and restoring the real files around each self-check
(a pattern that still leaves a real, if narrow, window where a process kill
mid-check could leave production state polluted), the entire gate self-check
block reassigns `-StateDir` and the derived `gate-decisions/`,
`gate-eligibility.json`, `gate-delivery.json`, and `artifact-signing.key`
paths to a freshly created, uniquely named sandbox directory
(`selfcheck-gate-sandbox-<guid>`, under the real `-StateDir` but never the
real files themselves) for the whole duration of self-checks 25-47, and
restores the real paths in a `finally` block afterward. Because every gate
function reads these as script-scope variables rather than parameters, this
reassignment is what every self-check - including ones that call the real
`Invoke-ReviewerGateReplay`/`Invoke-ReviewerGateForPullRequest`/etc. -
actually operates against. The real `gate-delivery.json`,
`gate-eligibility.json`, and `artifact-signing.key` are therefore never read
or written at any point during a dry run, not even briefly: a kill at any
moment during that whole window - a normal exception, Ctrl+C, or a hard
process termination that skips `finally` entirely - cannot damage production
pending state, because there is nothing to revert; only the one sandbox
directory is ever deleted, never a broader location.

## Producing a qualification artifact

`tools/New-ReviewerGateQualification.ps1` is an **operator-only** tool. It is
never invoked by the agent, is not reachable from any agent-facing CLI
switch, MCP tool, or config option, and contains no code path that runs an
evaluation itself - every precision/recall/sample/false-approval figure is a
parameter the operator supplies from a corpus they already scored elsewhere.
The tool's only job is to validate that shape, bind it to specific file
hashes and model names (hashing the reviewer script, the gate library, and
the cross-verification library/prompt/policy/schema the qualification is
being bound to), sign it with this deployment's own artifact-signing key
(creating it if this runs before the agent's first cycle), and write the
result in the exact schema `Get-ReviewerGateQualification` verifies. See the
tool's own comment-based help (`Get-Help ./tools/New-ReviewerGateQualification.ps1
-Full`) for its complete parameter list and a worked example.

## Reason codes

Every gate decision, and every candidate within it, carries a closed
vocabulary of reason codes - an unrecognized string is rewritten to
`unrecognizedReasonRewritten` and logged rather than passed through, the same
discipline cross-verification applies to a verifier's withheld reason.
Categories: policy (`gateDisabled`, `killSwitchEngaged`, `modeNotEnabled`,
`packDisabled`, `severityDisabled`, `suggestionGateDisabled`,
`runCapReached`, ...), qualification (`qualificationMissing`,
`qualificationExpired`, `qualificationBindingMismatch`,
`qualificationPrecisionBelowFloor`, `qualificationRecallBelowFloor`,
`qualificationSampleCountBelowFloor`, `qualificationFalseApprovalsPresent`,
...), artifact/binding (`artifactSignatureInvalid`, `artifactKindRejected`,
`artifactDomainMismatch`, `decisionExpired`, `scriptShaMismatch`, ...),
verification state (`verificationDegraded`, `candidateWithheld`,
`needsHumanPresent`, `specialistDegraded`, `generalistVoteNotApprove`,
`gateFindingsUndelivered`, ...),
world freshness (`sourceCommitMoved`, `changeSetMoved`, `threadDedupeHit`,
`blockingHumanThreadOpen`, `authoritativeSourceChanged`, ...), approval-only
(`checksUnavailable`, `checksFailed`, `dismissStaleReviewsUnknown`,
`eligibilityFirstSeenThisRun`, `canaryConfirmationMissing`,
`votePreviouslyCast`, `commentDeliveryIncomplete`), and gate-delivery record
lifecycle (`gateProcessingFaulted` - a bare processing exception, see
"Gate-delivery state machine"; `supersededRefreshBudgetExhausted` - the hard
supersede-refresh ceiling was reached, closing terminally instead of
inviting another fresh review). See `$script:ReviewerGateReasonCodes` in
`DeliveryGates.ps1` for the exhaustive list.

## A residual limitation, stated plainly

**The approval gate is unconditionally closed today.** The provider
capability reads it depends on - `Get-AgentProviderReviewDismissalPolicy` and
`Get-AgentProviderRequiredChecksSnapshot` - are implemented, unit-tested
against fixtures, and additionally exercised against a real, live, read-only
GitHub PR in `tools/Test-GitHubProviderLive.ps1`. But `Start-ReviewerAgent.ps1`
itself still hard-restricts `config.provider` to `"AzureDevOps"` only at
startup, and Azure DevOps unconditionally reports every one of these
capabilities as unknown for this layer's purposes
(`Get-ReviewerGateProviderCapabilities` returns `IsGitHub = $false` for it,
which alone fails `ProviderIsGitHub` in the approval predicate above). No
Azure DevOps equivalent of "dismiss reviews on push" or "required checks"
read was implemented for the gate - the honest state is that the approval
gate is real, tested code that cannot currently run against the one provider
this script supports. Comment and suggestion gating have no such
restriction and are provider-agnostic.

**`approval.allowOperatorAttestedDismissal` is accepted by the policy schema
and effective-policy resolution, but no code path ever reads it.**
Review-dismissal-on-push is always taken from the live
`Get-AgentProviderReviewDismissalPolicy` read, never from an operator's
say-so - this field exists in the schema but is inert by construction. An
operator setting it to `true` has no effect today.

**Sealing proves the file was not edited after this deployment signed it; it
does not audit the person who ran the evaluation.** See "What a signature
proves, and what it does not" above.

**GitHub ruleset-based branch protection is not read**, only the classic
branch-protection API (`Get-AgentProviderReviewDismissalPolicy`); a
repository that protects its branch exclusively through rulesets will report
`known = false` here and the approval gate will close, correctly but
conservatively.

**`AuthoritativeSourcesCurrent` is always `$false` today, unconditionally
closing approval on that term.** There is no live re-read of authoritative
convention-source content wired into the revalidation session, so rather than
pass an unverified `$true` through, `Invoke-ReviewerGateDelivery` always
supplies `$false` - honest, and costs nothing in practice today since
`ProviderIsGitHub` already closes approval unconditionally (above). A future
GitHub-enabled approval path must implement a real re-read/compare here
before this can ever be anything but `$false`; a `-DryRun` self-check pins
that the literal is `$false`, never `$true`.

**`checksSnapshotSha256`/`policySnapshotSha256` in a sealed decision are
always all-zero, by design, and never influence approval.** Checks and
review-dismissal policy are point-of-write facts, verified live at delivery
time (`ChecksKnown`/`ChecksAllSuccess`/`DismissalKnown`/`DismissesStaleReviews`
in `Test-ReviewerGateApproval`, from a FRESH revalidation), not point-of-
decision ones - there is nothing meaningful to hash yet when the decision is
sealed. These two binding fields exist purely for provenance/audit
completeness; `Test-ReviewerGateApproval` has no parameter for either one, so
neither can structurally ever authorize anything.

**The qualification tool's `evaluationToolSha256` binding has no live
counterpart unless an operator supplies one.** This script has no evaluation
tool of its own to hash at runtime - the evaluation tool is inherently an
external, operator-side artifact. By default this binding is accepted as
recorded provenance without independent re-verification. Supplying
`-GateEvaluationToolSha256 <hex64>` gives it a real, live counterpart: a
mismatch then closes the qualification (`qualificationToolMismatch`) exactly
like every other qualification binding. Either way, this is a third
out-of-band OPERATOR input, like `-GatePolicyFile`/`-GateQualificationFile` -
never something repository config can set.

**No end-to-end mocked test exercises a live unattended approval vote call.**
The approval *predicate* (`Test-ReviewerGateApproval`) has full boundary
coverage (149+ cases across `tools/Test-DeliveryGates.ps1`), and the
comments-incomplete-never-votes path, the replay-authority-refusal paths, and
the decision-binding-fatal-check paths are all exercised end to end via
`-DryRun` self-checks using real sealed artifacts and a deliberately-failing
fake Agency session. The full path with a real MCP session casting a real
vote is, by design, something this repository's offline test suite cannot
exercise - the same limitation raw delivery's own vote path has always had.

**The gate-refresh "no second raw delivery" substitution is unit-tested as a
pure function, not exercised through a live `Invoke-ReviewerPullRequest`
call.** `Get-ReviewerGateRefreshStandInDelivery` (what
`Invoke-ReviewerPullRequest` substitutes for a real `Invoke-ReviewerDelivery`
call when `Bound.RawDeliveryAlreadySatisfied` is set) is directly, `-DryRun`
tested for never posting/voting anything new and always carrying prior
capability outcomes through unchanged. The full path - a real multi-pass
model run against an already-raw-delivered commit, through merge, the
crash-safety placeholder, this substitution, and the final state write -
requires a live MCP session and model invocation this repository's offline
test suite cannot mock; the cycle-loop's own decision to set
`RawDeliveryAlreadySatisfied` (`Test-ReviewerAlreadyReviewed` combined with
`Test-ReviewerGateDecisionEverAttempted`) is covered directly, and the
gate-delivery state-machine transitions that trigger it (superseded,
faulted) are covered end to end via `-DryRun` self-checks 35 and 40.

## Live BPM sample remains preview/shadow only

The checked-in sample configuration for this repository's own review agent
does not enable any gate mode; `config.review.deliveryGates` there is
discoverable but inert (`disabled: false` with no out-of-repo policy, so the
kill switch has nothing to override and the shipped all-off default still
applies). Turning on any unattended gate capability against a real
repository is an operator decision made outside this repository, with an
out-of-repo policy file and a qualification artifact an operator produced and
placed there deliberately.
