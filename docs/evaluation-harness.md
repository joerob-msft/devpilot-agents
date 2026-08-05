# Evaluation harness and frozen corpus (layer 7)

Layer 7 measures the reviewer. It never delivers.

Nothing in this layer posts a comment, casts a vote, mints a delivery
authorization, promotes an artifact, or changes any write path. The reviewer
agent does not load it: `Start-ReviewerAgent.ps1` contains no reference to
`Evaluation.ps1` or to any evaluation function, and a test asserts that. Only
`tools/` loads it, and only a human runs `tools/`.

Its output is an **evaluation report**: a sealed, auditable, deliberately
non-promotable artifact that states what the reviewer's quality actually is on
a frozen, blind-labeled corpus, and whether those numbers would satisfy the
declared rollout bars. Turning that into a real gate qualification remains a
separate, deliberate human act through
`tools/New-ReviewerGateQualification.ps1`. There is no automation between the
two on purpose.

## Why the corpus and the verdicts are separate artifacts

An evaluation needs two different things from humans, and mixing them is the
classic way to get a number that means nothing:

- **What was actually wrong with this pull request?** Authored from the pull
  request alone, before and independently of any model output. This is the
  recall denominator, and it lives in the corpus.
- **Was this specific claim correct?** Necessarily authored while looking at
  model output. This is the precision numerator and denominator, and it lives
  in a separate adjudication artifact.

If the second contaminated the first, recall would be measured against
whatever the models happened to find, which is a tautology rather than a
measurement. So the corpus schema has no claim, arm, model, run, pack,
verdict, or matched-claim field anywhere in it, and
`Test-ReviewerEvalCorpusIntegrity` scans every nested key and rejects the
corpus if one appears.

## The four artifact kinds

| Kind | Contains | HMAC domain |
| --- | --- | --- |
| `reviewer-evaluation-corpus` | frozen ground truth, provenance, partitions, corrections | `devpilot.reviewer.evaluation.corpus.v1` |
| `reviewer-evaluation-run` | one arm's outputs over that corpus | `devpilot.reviewer.evaluation.run.v1` |
| `reviewer-evaluation-adjudication` | blind claim verdicts | `devpilot.reviewer.evaluation.adjudication.v1` |
| `reviewer-evaluation-report` | computed metrics, qualification, deficits | `devpilot.reviewer.evaluation.report.v1` |

Each is sealed under its own derived key, so none can be read back as any
other, and none can be read back as a verification or gate artifact.

### Non-promotability, stated precisely

Every evaluation artifact carries a `kind` and is sealed under an
evaluation-only HMAC domain. Both reviewer promotion paths therefore reject it:

- raw `-PromotePreview` verifies with the RAW master key, so a derived-domain
  envelope fails the signature check outright, and even if it did not, the raw
  path refuses any manifest that carries a `kind` property at all;
- `-PromoteVerifiedPreview` requires `kind == reviewer-gate-decision`.

The report's `promotable: false` / `authorizes: "none"` fields are for
auditability. They are not the control. The controls are the derived key and
the two kind checks on the promotion side, and the tests assert those rather
than the fields.

### The signing key is deliberately not the reviewer's

The harness signs with `evaluation-signing.key` in its own evaluation state
directory, and `Get-ReviewerEvalSigningKey` refuses a path named
`artifact-signing.key` outright.

Domain separation prevents artifact *confusion*. It does nothing about key
*possession*: whoever holds the reviewer state directory's signing key can mint
a `reviewer-gate-qualification` and a `reviewer-gate-decision`. If the harness
opened that key, every host that ever ran an evaluation - a CI runner, a shared
build agent, a future automated job - would inherit the ability to mint
delivery authorization. That is the exact bypass this layer must not create.

The by-name refusal is a guard-rail against the obvious operator mistake, not a
security boundary: a copy or a rename defeats it. The actual boundary is that
this library has no code path that emits a gate or delivery kind at all, and
seals only under derived `devpilot.reviewer.evaluation.<domain>.v1` keys.

Evaluation sealing is tamper-evidence over an audit trail. It is not, and is
not intended to be, a delivery trust root.

## Freezing a corpus

```powershell
./tools/Import-ReviewerEvalCorpus.ps1 `
    -ImportManifest C:\eval\import-2026Q1.json `
    -OutputPath C:\eval\corpus-v1.json `
    -StateDir C:\eval\state `
    -DeficitPath C:\eval\corpus-v1.deficit.json
```

The import tool curates. It does not collect and it does not label. It refuses
to:

- mark a record `qualifying` when its commit or change-set pin is an all-zero
  placeholder;
- accept a record with fewer than two independent human labels;
- import any record whose `status` is `seed`, or whose pins are placeholders,
  without an explicit `-AllowSyntheticSeed` acknowledgement. The switch does not
  set `status` - the import manifest does - and any seed record trips the
  `seedCorpus` global veto;
- silently rewrite an existing frozen corpus without `-Force`.

Identity is derived, never asserted:

- `exampleId = sha256(domain, {provider, repositoryId, prId, sourceCommitSha, targetCommitSha, changeSetSha256})`
- `groupKey = sha256(domain, {repositoryId, changedFilePathsSha256})`
- `recordHash = sha256(domain, <the record minus its own hash>)`
- `freeze.corpusSha256 = sha256(domain, {name, corpusVersion, corpusPin, frozenAtEpochSeconds, partitionPolicy, strata, corrections, ordinal-sorted record hashes})`

The freeze digest deliberately covers the corpus's own name, version and pin,
not just its records. The pin is what an operator eventually transcribes into a
gate qualification as `repositoryId`/`commitSha`; if it sat outside the digest,
a re-seal under a different pin would leave every existing run and adjudication
verifying clean and the transcribed pin would never actually have been frozen.
Run manifests are checked against the corpus name as well as its digest for the
same reason.

### Partitions, and why they are grouped and stratified

Partition assignment is deterministic, label-blind, stratified, and
coverage-aware:

1. Examples are grouped by `(repositoryId, changed-file path set)`. A revert, a
   retarget, a rebase, or a re-open of the same change has a different PR id and
   different commits but the same changed-file set, so partitioning by
   `exampleId` alone would scatter near-twins across calibration and holdout.
   That is textbook leakage.
2. Within each stratum, whole groups are ordered by a salted domain hash and
   the first `ceil(holdoutPercent x groups / 100)` become holdout, capped so a
   stratum can never be emptied into one side.
3. The harness re-derives the whole assignment and rejects any stored partition
   that disagrees, any example that appears twice, any change-set that appears
   in both partitions, and any group that straddles the split.

`partitionSalt`, `adjudicationSalt` and `holdoutPercent` are frozen inside the
signed corpus and are **not** policy keys. A salt that policy could edit would
be a one-line way to reshuffle an inconvenient example out of holdout;
`ConvertTo-ReviewerEvalEffectivePolicy` throws if a policy file even mentions
them.

### Ground truth, disagreement, and corrections

Each example carries at least two independent, blind, human labels. Ground
truth is *derived*, never authored directly:

- all labels agree -> `concordant`, and that is the ground truth;
- labels disagree -> an adjudicator who is **not** one of the labelers decides,
  and the result is `adjudicated`;
- labels disagree with no independent adjudicator -> `disputed`. A disputed
  example resolves to nothing: it contributes to no recall denominator, no vote
  denominator, and no precision denominator. It is not silently resolved in
  either direction.

The stored `groundTruth` block must equal that reconciliation exactly, or the
corpus is rejected.

Corrections are the only sanctioned post-freeze channel, which makes them the
one an operator holding run results would reach for. Each is an appended,
sequence-numbered entry with a human author from a closed reason vocabulary,
superseding a specific record hash and bumping `corpusVersion`. The harness
compares each correction's timestamp against the earliest bound run: a
correction authored after the arms ran sets `postRunCorrection`, which fails
every rollout requirement closed.

### No ISO-8601 timestamps, anywhere

`ConvertFrom-Json` rehydrates an ISO-8601-shaped string as a `[DateTime]`, and
the canonicalizer this stack uses throws on `[DateTime]`. An artifact that
stored ISO text could be signed once and then never re-verified, because
recomputing a record hash after a round trip would crash. Every instant in
every evaluation artifact is therefore an integer `...EpochSeconds` field, the
sealer refuses a `DateTime` value, and the reader rejects an artifact that
reintroduces one.

## The three arms

| Arm | What it represents |
| --- | --- |
| `generalistOnly` | the two independent generalist passes, no specialist, no verification |
| `multiPassDiscovery` | generalists plus convention-specialist discovery |
| `verified` | the independently cross-verified output |

`Test-ReviewerEvalRunSetConsistent` requires the three arms to be the same
measurement taken three ways: identical corpus hash, byte-identical
code/config/prompt/schema binding, identical configured model identities,
identical example set, and identical `(sourceCommitSha, targetCommitSha,
changeSetSha256)` per example. A mismatched or stale pair is rejected outright,
not annotated - a delta between two different experiments is a category error,
not a result.

Each run manifest is split deliberately:

- `derivation` is deterministic and is what replay equality compares;
- `observations` records latency, token counts and cost. These are
  operator-asserted wall-clock facts that this layer cannot recompute - it does
  not execute the arms - so what it checks instead is that the pinned pricing
  table covers every model the arm declares, making a cost figure at least
  attributable to a rate card.

The report exposes `derivationSha256` and `observationsSha256` separately for
exactly that reason.

## Blind adjudication

Verdicts are filed against a content-derived key:

```
blindClaimKey = sha256(domain, {corpusSha256, exampleId, path, severity, claimContentSha256})
```

and the adjudication artifact carries **no** arm, model, run, pack, cluster,
pass, partition, stratum, issue-class or convention field. Blindness is
enforced three ways, not asserted:

1. **A presented-field allowlist.** An adjudicator sees exactly
   `blindClaimKey`, `claimContentSha256`, `path`, `severity`, `text`. The
   convention flag and the issue class stay in the run manifest, because only
   the specialist-bearing arms populate those distinctively. Each verdict binds
   `presentedSha256` over that exact projection, and the harness recomputes it.
2. **A salted presentation order.** Order is derived from
   `sha256(domain, {adjudicationSalt, blindClaimKey})`, never from run or arm
   order, so position cannot reveal the producing arm.
3. **A forbidden-key scan** over every nested key in the artifact.

Two arms that produce the same claim about the same anchor share one verdict.
That is a convenience, not the blindness mechanism.

Per claim: at least two independent human verdicts from
`{truePositive, falsePositive, abstain}`, plus `matchedIssueIds` naming which
ground-truth issues the claim actually found. Reconciliation is deterministic:
concordant verdicts stand (with the *intersected* match set, so only issues
every labeler independently reported count toward recall); a discordant claim
needs an independent adjudicator; without one it is `disputed`.

**Recall matching is a human judgment, on purpose.** There is no similarity
threshold anywhere on the recall path. Text-matching a claim to an inventory
item would let model output decide what counts as "found", which is the
contamination this design exists to prevent, and would silently move every
recall number whenever the threshold moved.

Abstentions and disputes leave both the numerator and the denominator, and
instead reduce `adjudicationCoverage`, which is its own floor. Otherwise
precision could be driven arbitrarily high just by abstaining on every hard
claim. Inter-labeler agreement is reported as Fleiss' kappa and has a floor of
its own; an undefined kappa fails closed rather than reading as agreement.

## Metrics

Per arm and per partition: raw precision, unique-claim precision, duplicate
rate, severity accuracy, correctness recall, convention recall, per-issue-class
recall, vote accuracy, would-approve and false-approval counts, latency median
and p95, token totals, and cost.

Denominator discipline, applied everywhere:

- only examples whose run status is `complete` contribute anything; a
  `degraded`, `unknown` or `missing` example is excluded from every denominator
  (so it cannot silently depress recall) and is counted separately, where it
  becomes a fail-closed veto;
- only claims with a **resolved** verdict enter a precision numerator or
  denominator;
- unique-claim metrics collapse duplicates by `blindClaimKey` within an
  `(arm, example)`; raw metrics do not. Both are reported, so a sample-size
  floor can never be met by the same finding restated five times;
- recall denominators are the *agreed* ground-truth issues, not the whole
  candidate inventory;
- a zero denominator yields `null`, never `0` and never `1`.

## Confidence intervals: exact, not approximate

Every qualification decision is a comparison of exact integers.

The one-sided Clopper-Pearson lower bound `L(x, n)` satisfies
`P(X >= x | n, L) = alpha`, and that tail increases in `p`, so

```
L(x, n) >= p0   <=>   P(X >= x | n, p0) <= alpha
```

With `p0 = a/b` and `alpha = aNum/aDen` that is a `System.Numerics.BigInteger`
comparison:

```
aDen * SUM_{k=x..n} C(n,k) a^k (b-a)^(n-k)  <=  aNum * b^n
```

which is bit-identical on every host. The symmetric identity gives the upper
bound: `U(x, n) <= p1  <=>  P(X <= x | n, p1) <= alpha`, and
`P(X <= x | n, p) = P(Y >= n-x | n, 1-p)`, so one tail routine serves both. The
tail uses an exact term-ratio recurrence, so each step multiplies and divides a
large accumulator by small integers rather than multiplying two large numbers.

**No transcendental function appears anywhere on a metric or interval path.**
.NET does not guarantee bit-identical `Pow`/`Log`/`Exp` results across
platforms and runtime versions, and a bound that differed in its last bit
between a Windows and a Linux runner would break both replay equality and a
threshold comparison at the boundary. A test asserts the library contains none.

Reported bounds are searched on a fixed 1e-4 decimal grid and are one-sided
conservative by construction: a reported lower bound is the largest grid point
that still passes the exact test, and a reported upper bound is the smallest
grid point that fails it. Every threshold this layer uses (0.98, 0.95, 0.02,
0.01) lands exactly on that grid, so quantization can never move a number
across a threshold. Reported bounds are informational; the exact integer
predicates are what decide.

Edge cases, explicitly:

| Case | Behavior |
| --- | --- |
| `x = 0` | lower bound is exactly 0 |
| `x = n` | lower bound is `alpha^(1/n)`, found on the grid |
| `n = 0` | bound is `null`; every dependent requirement fails closed |
| `n` above the exact ceiling | bound is `null` and qualification refuses, rather than falling back to a non-reproducible approximation |

Multiplicity is handled by Bonferroni over the **prespecified** qualifiable
scopes declared in policy: `alpha = 1/(20 x K)`. Searching three arms by three
severities by N packs for one that clears 95% is not a 95% claim. The scope
list is versioned, and the adjustment is recorded in the `boundMethod` string
(`clopper-pearson-1sided-95-bonferroni-kN`) so a transcribed qualification
carries it. Pooling across severities or across packs is structurally
impossible: `Get-ReviewerEvalScopeMetrics` computes one `(pack, severity)`
scope at a time.

A policy that declares **no** important/critical scope fails closed with
`commentScopeNotDeclared` rather than quietly deleting the per-scope evidence
requirement (and, with it, the multiplicity penalty). The schema additionally
requires at least one declared scope.

### Recall regression is paired

Both arms ran the same examples at the same pinned commits, so differencing two
independent point estimates would ignore that correlation and let ordinary
noise clear a 2-point bar. The primary endpoint is prespecified: holdout
correctness recall over an identical inventory denominator, with an exact
discordant-pair (McNemar-style) **upper** bound on the regression. With `b`
baseline-only hits and `c` candidate-only hits, the regression is
`(2b - nd)/N` where `nd = b + c`, so an upper bound `U` on `b/nd` bounds the
regression by `nd(2U - 1)/N`, and the requirement rearranges to the exact
rational threshold `U <= (r*N + nd) / (2*nd)`. Zero discordant pairs means the
regression is exactly zero; a zero inventory denominator fails closed.

## Rollout qualification

| Requirement | Bars |
| --- | --- |
| `unattendedImportantCriticalComments` | >= 200 eligible holdout findings; observed precision >= 98%; exact lower 95% bound >= 95%; a non-empty adjudicated critical stratum with zero critical false positives and an exact upper bound on the critical false-positive rate; paired recall regression upper bound <= 2 points; every declared important/critical scope clears its own bound |
| `unattendedSuggestionComments` | always `suggestionsPreviewOnly` unless separately enabled AND a suggestion scope is declared AND it clears the same bars on its own |
| `approvalVote` | >= 300 labeled holdout decisions, a non-empty would-approve stratum, zero false approvals, and an exact upper bound on the false-approval rate |

An **eligible holdout finding** is: holdout partition, `verified` arm, example
status `complete`, severity in `{important, critical}`, counted once per
`blindClaimKey`, with a resolved verdict. `rawClaims` and `duplicateRate` are
reported separately so the 200 floor can never be met by duplicates.

Global vetoes apply to every requirement: corpus integrity failure, run-set
inconsistency, adjudication failure, any seed record, zero qualifying examples,
population below the declared minimums, any unpopulated stratum, any
degraded/unknown/missing evidence, adjudication coverage below its floor, and
an undefined or below-floor agreement statistic.

**"Zero bad events" always needs a denominator.** An arm that produced no
critical claims has zero critical false positives, and an arm that never
approves has zero false approvals. Both would sail through a naive
count-based veto. So each zero-event veto additionally requires a minimum
adjudicated stratum size and an exact upper bound on the rate;
`criticalStratumEmpty` and `approvalStratumEmpty` are failures, not passes.

### This is necessary, not sufficient

A fully qualifying report still cannot make `critical` severity unattended.
`DeliveryGates.ps1` excludes `critical` from its code-defined unattended
severity ceiling and no policy, artifact or report can restore it. Layer 7
reports what the numbers are; layer 6 decides what is reachable, and it is
strictly narrower.

## Running an evaluation

```powershell
./tools/Invoke-ReviewerEvaluation.ps1 `
    -CorpusFile C:\eval\corpus-v1.json `
    -RunFiles C:\eval\run-baseline.json,C:\eval\run-multipass.json,C:\eval\run-verified.json `
    -AdjudicationFile C:\eval\adjudication-v1.json `
    -StateDir C:\eval\state `
    -OutputPath C:\eval\report-v1.json `
    -ReportVersion 1
```

Pass `-GeneratedAtEpochSeconds <original>` to reproduce a byte-identical report
from identical inputs; that is what makes replay verification meaningful. Use
`-SealOnly -SealKind run|adjudication -SealInput <plain.json>` to seal a
plain-JSON manifest into the corresponding domain first.

The `toolBinding` block hashes every file that can change a number - the
library where the math lives, both tools, the policy, and all four schemas -
and folds them into one composite `evaluationToolSha256`. That composite is
what an operator passes to the reviewer's `-GateEvaluationToolSha256`, so a
qualification cannot be bound to a thin entry point while the scoring code
changes underneath it.

## Corpus population truth

This repository ships **no real corpus**. `src/Agents/reviewer/testdata/evaluation-import-v1.seed.json`
and `evaluation-arms-v1.seed.json` are synthetic seed fixtures that exist to
exercise the harness offline. Every record is `status: "seed"`, and a seed
record can never satisfy a rollout requirement no matter how good its numbers
look - the single most important test in `tools/Test-ReviewerEvaluation.ps1`
proves exactly that, by feeding perfect metrics at a large sample size through
the qualification predicate and asserting it still qualifies nothing.

Reaching the target population (>= 100 examples, 80 calibration / 20 holdout,
every stratum populated, and enough holdout findings and labeled decisions to
clear the 200/300 floors) requires genuinely sourced, provenance-bound pull
requests imported through `tools/Import-ReviewerEvalCorpus.ps1`. Until then the
report's `corpusPopulation.deficits` array and the import tool's deficit file
state the shortfall in machine-readable form, and every requirement fails
closed. That is deliberate: an honest deficit beats a lowered gate.

## Residual limitations, stated plainly

- **The harness scores; it does not run the arms.** Run manifests - including
  model identities, latency, token counts and cost - are operator-authored and
  sealed with `-SealOnly`. This layer verifies their structure, their pinning,
  their mutual consistency, and that the pricing table covers every declared
  model; it cannot verify that the numbers describe a real execution.
- **Reviewer-side bindings are recorded provenance, not live verification.**
  `derivation.binding` records which reviewer script, gate library,
  verification library, prompt, policy and schema produced a run, and all three
  arms must agree byte-for-byte with each other - but agreement among the arms
  is not proof that any of them matches a real artifact. Supply
  `-ConfigSha256`, `-ReviewerScriptSha256`, `-GateLibrarySha256`,
  `-VerificationLibrarySha256` and/or `-VerificationPolicySha256` to turn a
  recorded value into a live cross-check. They are operator inputs on purpose:
  scoring an older reviewer build is a legitimate thing to do.
- **"Untouched holdout" is a process guarantee, not an enforced one.**
  Partitions are frozen, group-consistent and leakage-checked, and a
  post-run ground-truth correction is detected - but nothing prevents an
  operator from scoring repeatedly against the same holdout across successive
  corpus versions. That discipline lives outside the repository.
- **Per-scope evidence is only as wide as the declared scope list.** Declaring
  only an `important` scope removes the per-`(pack, severity)` critical bound;
  the aggregate critical-stratum checks still apply. The Bonferroni `k` is the
  size of that declared list, so a shorter list is a weaker multiplicity
  correction as well as narrower evidence - declare every scope you intend to
  qualify, before you look at the numbers.
- **Transcribe `corpus.sha256` explicitly.** The report's
  `transcriptionInput.corpus.sha256` is the corpus FREEZE digest, which is not
  what `New-ReviewerGateQualification.ps1 -CorpusPath` computes (that hashes
  the sealed file on disk). Use `-CorpusSha256 <value>` with the transcribed
  number, or the qualification will bind a different one.
- **Eligibility here is not layer 6's live predicate.** `Test-ReviewerGateCandidateEligible`
  needs live pull-request world state (thread dedupe, anchor validity, check
  status) that a frozen offline corpus does not carry. Layer 7's "eligible
  holdout finding" is the partition/arm/severity/resolution definition above.
  It is a superset in some cases, so a qualification derived from it is not a
  guarantee that the same findings would pass the live gate.
- **Approval qualification uses the holdout partition only.** That is the
  conservative choice and it is demanding: 300 holdout decisions at a 20%
  holdout implies a corpus of roughly 1,500 pull requests.
- **A signature proves the artifact was not edited, not that the labels are
  honest.** Who may label, adjudicate, and publish a corpus is an
  organizational boundary, not a cryptographic one, and no tool inside the
  repository under review can close it.
- **Blindness is enforced structurally, not perfectly.** The allowlist and
  salted order remove the mechanical tells. A sufficiently distinctive claim
  style could still hint at its origin to an experienced adjudicator, and no
  schema can prevent that.
