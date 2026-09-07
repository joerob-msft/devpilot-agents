# Convention pack schema and matching

Convention packs are an optional wrapper-owned routing surface under
`repoConventions.conventionPacks`. This layer selects and budgets context for a
future convention specialist. It does not launch that specialist and does not add
pack context to the existing generalist review prompt or runtime context.

## Version 1 schema

Every object has exact keys. `note` is allowed only where shown by the sample;
unknown keys, wrong JSON types, coercible strings, and out-of-range integers fail
startup.

```json
{
  "schemaVersion": 1,
  "requireAllSourcesReferenced": true,
  "authoritativeSources": {
    "transportVersion": 1,
    "maxTotalBytes": 8192,
    "sources": [
      {
        "name": "shared-rules",
        "organization": "contoso",
        "project": "ExampleProject",
        "repositoryId": "11111111-2222-3333-4444-555555555555",
        "path": "/reviewer/conventions/shared.md",
        "branch": "main",
        "maxBytes": 4096
      }
    ]
  },
  "packs": [
    {
      "name": "csharp-core",
      "priority": 100,
      "changedPathGlobs": ["src/**/*.cs"],
      "authoritativeSourceRefs": ["shared-rules"],
      "repositorySources": [
        {
          "path": "/docs/conventions/csharp.md",
          "maxBytes": 2048
        }
      ],
      "maxBytes": 8192
    }
  ]
}
```

Pack and source names are exact lowercase ASCII identifiers. Pack names are
unique. Canonically duplicate source identities and duplicate semantic pack
definitions are rejected even when their names differ. Source references must
resolve within this pack-only catalog. When `requireAllSourcesReferenced` is true,
every configured authoritative source must have at least one pack use. A pack
must have at least one glob and at least one authoritative or repository-local
source.

The pack source catalog is intentionally separate from the legacy
`repoConventions.authoritativeSources` catalog. Both use transport version 1 and
the same fail-closed source verification, but only the legacy catalog is rendered
into the existing generalist context.

## Matching and precedence

After pending delivery retries, the wrapper opens one dedicated, repos-only MCP
session for each PR's convention plan. Target resolution, both change-set reads,
the intervening PR binding read, authoritative pack sources, and repository-local
sources all use that owned session. A convention transport fault therefore cannot
abort the shared review session that owns later candidates and delivery. The
dedicated session is organization-bound, credential-scrubbed, and closed in a
`finally` path before the wrapper handles success or failure.

The wrapper reads the PR change set twice around exact source-commit and
target-branch checks. Both normalized change-set digests must agree. A response at
the transport's 1000-entry ceiling is treated as potentially truncated and fails
closed. An active PR response that normalizes to zero file entries also fails
closed with an explicit unknown/empty-change-set reason; it is never converted
into a ready plan that withholds every pack. This is an intentional hard gate:
the PR receives no convention specialist or generalist model launch, and repeated
deterministic failures count toward the configured starvation threshold. That
trade-off prevents an anomalous empty transport response from silently weakening
the review.

Globs are repository-relative. For matching only, ADO `/src/a.cs`, Windows
`\src\a.cs`, and `src/a.cs` normalize to `src/a.cs`. The canonical anchored path
remains `/src/a.cs` in routing evidence and downstream artifacts. Drive, UNC,
control, empty, doubled-separator, and `.`/`..` forms are rejected. Comparison is
ordinal case-insensitive without Unicode normalization. Configured globs are
ASCII and support:

| Form | Meaning |
|---|---|
| `*` | Zero or more characters inside one segment |
| `?` | One character inside one segment |
| `**` | Zero or more complete path segments |

`**/x.cs` therefore matches both `x.cs` and `src/x.cs`. A bare `**`, adjacent
`**/**`, partial `foo**`, character class, brace, extglob, escape, or traversal
form is unsupported.

Adds and edits match their current path. Deletes match the deleted path. Renames
match both the previous and current path, including ADO comma-separated and
integer-bitmask change types. Unknown change types match every safe path carried
by the entry rather than silently under-selecting. Folder entries do not match.
Generated files receive no global exception and are routed only by explicit
globs.

All matching globs are retained as evidence. Duplicate path/role entries collapse
case-insensitively within a pack. One path may select several packs. Selected packs
sort by ascending numeric priority and then exact pack name; equal priorities are
therefore deterministic rather than ambiguous. Unmatched packs are recorded as
withheld and their sources are never requested.

## Provenance and budgets

Pack authoritative sources are resolved exactly like transport version 1:
organization, project, repository GUID, branch, exact commit, canonical path,
strict UTF-8 MIME, decoded byte length, and SHA-256 remain bound together.
Repository-local sources use the same resource decoder but resolve from the
stable target-branch commit. Plans label these tiers `pinned-external` and
`repo-target`, so a later renderer cannot flatten their trust.

`maxBytes` is not a text-only allowance. It includes every selected source's
decoded bytes plus the exact compact JSON descriptor containing the pack name,
priority, and source provenance. Routing evidence (matched paths and globs) is
persisted and byte-counted separately because it identifies why context was
selected; it is not convention context and cannot consume or bypass a source
context cap. Startup computes worst-case provenance with every source's declared
maximum byte length, the longest allowed MIME representation, and the exact
configured identities, paths, and refs. A cap equal to that required maximum is
accepted and one byte less is rejected, which guarantees any individually valid
source snapshot fits its pack at runtime. The total convention-context cap is
code-defined at 131072 bytes and cannot be widened by config. Broader multi-pack
overlap remains runtime fail-closed because a whole change set can co-select packs
whose globs never intersect on one path; startup does not over-reject mutually
exclusive packs. Per-pack and total accounting conservatively charge a reused
source to each selected pack.

No rule is truncated. A cap or deterministic provenance failure writes a
structured failed plan, increments that PR's bounded failure count, prevents that
PR's model launch, and leaves other PRs in the cycle eligible. Transport,
credential, timeout, or concurrent source/target movement also fails that PR
closed, but is recorded as an environment fault and does not push the PR toward
starvation.

Ready plans contain no decoded convention text. They contain exact source
coordinates, hashes, byte counts, selection evidence, script/config hashes, and
the change-set digest needed by the optional specialist to resolve and verify the
same bytes. Plans are HMAC-sealed under the reviewer state directory's
`convention-plans` folder and are not posted or voted on.

The next wrapper-only layer extracts deterministic review facts from that same
immutable snapshot. See [Deterministic review facts](review-facts.md). Fact plans
remain separate artifacts and do not enter the current generalist prompt.

## Optional convention-specialist discovery

`-EnableConventionSpecialist` adds a third, independent discovery pass only when
an explicit model is supplied with `-ConventionSpecialistModel` or
`review.conventionSpecialistModel`. There is no implicit CLI model. The
specialist runs after the generalist review, delivery state, and exit result are
finalized. Its candidates never enter the merged review artifact, comments,
summary, vote, pass-completion accounting, or promotion path.

The specialist receives only the dedicated prompt, the sealed fact and
convention plans, exact convention text re-resolved at each recorded commit and
SHA-256, the pinned changed-file records, sanitized thread metadata, and two
read-only tools: pull-request and repository-file reads.

Two nonce-bound result contracts are supported. Contract v2 is frozen and
retained as a read-only compatibility contract for sealed transcripts and
previews already on disk; it keeps the historical shape in which a candidate
retyped its anchor and source provenance. Contract v3 is the live specialist
contract. Its candidates no longer restate file path, line, pack name, or
rule-source provenance: the wrapper derives the anchor from `primaryTarget` and
derives provenance from `ruleRef` (`rs0`, `rs1`, ...), the requested rule row the
candidate is about. Candidate `factIds` may cite either review facts (`rf1:`) or
declaration-census facts (`rdf1:`). Both contracts permit `suggestion` and
`important` convention candidates only. Wrapper validation rechecks source
quotes, pack membership, fact IDs, severity rules, sibling evidence, and current
changed-file anchors. Invalid anchors are withheld rather than relocated.

Contract v3 also opts the candidate array into per-element degradation. One
unreadable candidate is reported through `DroppedElements` and becomes a
`withheld` entry with reason `schemaInvalidCandidate`; it does not discard the
whole marker or the other candidates. Binding fields stay marker-atomic, and
structural failures such as a non-array, excessive item count, malformed element
schema, or wrong top-level binding still fail closed. Dropped elements are always
reported so a shortened candidate list is never read as a clean review.

Each candidate carries two exact remediation parts. `changedCodeFix` is the
required stop-the-bleed action on sealed changed constructs. It identifies the
generic convention key and whether an exact value comes from deterministic facts
or must be obtained from the authoritative rule; the wrapper never guesses an
identity or assignee. `existingDebtFollowUp` is explicitly `none` unless a
complete wrapper-generated `rdf1:` file summary proves a bounded systematic
pattern. An authoritative-rule `selectorKey` must identify at least four
declarations in the sealed frequency table, the required convention key must
appear on zero declarations, counts must be complete, and the sealed
generated-code classifier must be false. Complete means the source transport
delivered every textual line of the exact pinned file without gaps or
truncation; the census fact binds that proof to the pinned whole-file digest.
Hunk and sibling slices alone can never establish a complete census.
When supported it requests recording or linking a scoped follow-up issue/PR,
never unrelated cleanup in the current pull request. Partial counts,
counterexamples, generated code, unrelated paths, ambiguous boundaries, and
repo-wide claims fail closed to `none`.

Every run, including timeout, process failure, or invalid output, writes a
separate Markdown preview and domain-separated HMAC artifact under
`convention-specialist-previews`. The artifact records model, prompt/script/
config/plan/fact hashes, pack names, context bytes, granted and observed tools,
withheld reasons, and residual risks. Degradation is diagnostic in this layer;
it does not change generalist publication or voting.

## Rule-coverage accounting

Transporting a rule is not the same as checking it. A specialist that reads
eight rules, checks two, and reports one finding has said nothing at all about
the other six - and "nothing" is exactly what a miss looks like from the
outside.

So the marker carries a bounded `ruleCoverage` array alongside `candidates`, and
the wrapper tells the model exactly which rows it expects. `ruleCoverageRequest`
in the runtime data names one required row per transported source, the `cf<n>`
anchor ids for the changed files the wrapper delivered, and the wrapper's own
enumeration of every **changed construct** in the change set. Each row states:

- the pack, source id and source hash it is about, and an exact quote from it;
- a `status` of `violation`, `compliant`, `notApplicable` or `unknown` - which
  the wrapper **derives** from the verdicts below rather than taking on trust;
- a `scope`: the construct kinds the rule governs, or `none`;
- a verdict for **every** anchor in the sealed construct table, split across
  four disjoint lists that together equal that full universe exactly:
  `violatingConstructs`,
  `compliantConstructs`, `notInReachConstructs` (examined, and the rule does
  not reach it) and `unknownConstructs` (could not decide);
- the code evidence, and the sibling evidence or why none was needed;
- the id of the candidate it produced, or a note saying why none was emitted.

`unknown` is a first-class answer. Source that was not delivered, sibling
practice that could not be established and ambiguous rule text are all honest
`unknown`s, and each says which in its note.

### Contract v4: the per-construct verdict matrix

The accounting above is what the model produces under contract **v3**. Contract
**v4** keeps every guarantee and moves the arithmetic behind it to the wrapper.

Ten measured qualification runs of v3 found all nine violating declarations in a
real pull request every time, with zero false positives - and lost the finding
anyway. Not to bad judgement: to a `primaryTarget` written as a construct id
rather than a line anchor, to six different spellings of one `conventionKey`
across ten runs, to a `notInReachConstructs` list that named the three in-scope
declarations correctly and omitted the twenty-five out-of-kind ids it was the
set-complement of, and to a row `status` the wrapper already derived and
overrode. Every one of those is transport or arithmetic the wrapper holds.

So v4 asks for the one thing the wrapper does not hold - a verdict on each
construct - and derives the rest:

```
assessments[]                one row per requested rule
  ruleRef                    rs0, rs1, ... - the rule this row answers
  constructs[]               EXACTLY one entry per id in the row's inScopeConstructs
    constructRef             an opaque dc/mi/cm/as id the wrapper minted
    verdict                  violation | compliant | unknown
  notes[]                    up to eight short explanations, violations only
    constructRef, rationale, suggestion
```

That is the whole model surface: two required leaves per construct. There is no
`candidates` array and no `ruleCoverage` array in a v4 marker - the wrapper
builds both.

**In scope is decided by pack routing.** Each requested row carries
`inScopeConstructs`: the exact, range-compressed id set that rule reaches,
computed from the `changedPathGlobs` the pack already matched. The model never
computes a set. Constructs in files the pack did not route to are ruled out of
reach by the wrapper. A pack with no routing evidence is reported as
**unresolved**, never as an empty scope - "this rule reaches nothing here" is a
claim, and "the wrapper cannot tell" is not the same claim.

**Omission is never compliance.** A row must carry exactly one verdict per
in-scope id. A missing, duplicated or unrequested `constructRef` makes the whole
row incomplete: its verdicts are discarded, every construct it reaches is
recorded `unknown`, and it publishes no finding. This is the anti-silence
mechanism from v3, moved off the model's set arithmetic and onto the wrapper's.

**Grouping is a wrapper decision.** Violating constructs are grouped by
`(rule, file)` in ordinal order and each group becomes one candidate. A model
that answers per file and one that answers in a single block are therefore the
same input and produce identical output - so a correct split can no longer be
scored as a miss. Coverage is the **union** of every accepted candidate's
anchors, never a property of one chosen candidate.

**Prose cannot cost a verdict.** `notes` are bounded separately, capped at eight
per row, and drop individually. An unreadable, over-long or duplicated note
discards only itself.

The wrapper derives, and the model never states: the candidate id, the primary
anchor and its file and line, every manifestation, the pack and all five
rule-source provenance fields, the rule section and quote, the evidence fact ids,
the sibling status and evidence, the severity and impact category, the structured
fix metadata, the four-way construct partition, the row status, and the rule
accounting. The candidate the wrapper emits keeps the v3 shape exactly, so
cross-verification, reconciliation and delivery are unchanged by v4.

Two limitations, stated rather than implied:

- **No kind-level scoping.** In scope is derived from file routing only, so
  within a routed file every construct kind is in scope and `compliant` means
  "does not violate this rule" rather than "in reach and complying". Recovering
  the kind distinction needs one additional per-pack key (a rule `scopeKinds`),
  which this contract deliberately does not add.
- **No cross-construct claims.** A rule whose claim is about a *relationship
  between* constructs can only be expressed as independent per-construct
  verdicts that wrapper grouping collects; the model cannot state the relation.

### The version ladder

| Contract | Prefix | Status |
|---|---|---|
| v2 | `CONVENTION_REVIEW_RESULT_V2:` | **Frozen.** Sealed transcripts and previews on disk were produced against it. Nothing in it may change shape. |
| v3 | `CONVENTION_REVIEW_RESULT_V3:` | **Readable.** No live caller, but sealed v3 artifacts still verify, against the v3 prompt whose digest they recorded. |
| v4 | `CONVENTION_REVIEW_RESULT_V4:` | **Live.** |

Each version has its own prefix and its own prompt file, so a reader decides
which contract it is reading before it parses anything, and a `promptSha256` that
sealed an older artifact never moves. A response carrying **two** known prefixes
is ambiguous about which contract it was written against and is refused outright
rather than resolved to one of them.

### Changed constructs

The wrapper enumerates four kinds of changed construct, lexically and without
knowing anything about the repository, its language's testing framework, or what
any attribute means:

| Kind | Id | What it is | Shape facts carried |
| --- | --- | --- | --- |
| `invocation` | `mi<n>` | a call spanning more than one line | callee, argument count, and one character per argument: `n` syntactically named, `p` positional |
| `declaration` | `dc<n>` | a changed declaration | the attributes on it, the attributes on its nearest unchanged neighbours, and `absentHere` - attribute names present on unchanged declarations elsewhere in the file but not on this one |
| `comment` | `cm<n>` | a run of contiguous changed comment lines | first and last line |
| `assignment` | `as<n>` | a changed statement writing to a name that already exists | the target |

`constructFileSummaries` additionally counts how often each attribute appears
across each whole file, so "the surrounding code already does this" is a number
rather than an impression.

The `bpm-test-ownership` capability is generic convention evidence, not a
hardcoded parser rule. When a transported rule requires an owner attribute on
test classes and test methods, the specialist applies that text to changed
declarations. Combined attribute lists and `DataTestMethod`/`DataRow` forms are
in scope because the wrapper reports declaration attributes as syntax facts. If
the required declaration context is unavailable - for example a truncated
attribute list, undelivered lines, an unlexable file, or construct caps hit - the
row is `unknown`, not `compliant`, and no finding is emitted.

The enumeration decides *shape*, never *meaning*. It cannot declare a violation:
only the transported rule text, read by the model, decides whether a construct
is in a rule's reach and whether it breaks it. There are no employer-specific or
framework-specific patterns anywhere in it.

Budgets are split evenly across kinds and taken round-robin across files, so
neither a call-heavy change set nor a file that sorts first can starve a kind or
a file of anchors. When a cap or an unlexable file means the enumeration is
incomplete, the accounting is reported incomplete too - a checklist that covers
every rule over a construct set that is missing entries has not covered the
change set.

Construct id lists accept inclusive same-kind ranges (`mi0-mi37,dc0-dc18`).
Without that a complete answer over a real change set does not fit in a field
short enough to survive the marker's length bound, and an answer that cannot be
written gets written incompletely.

The wrapper then reconciles the rows against the set it transported, which it
computed itself:

- a source with no row is reported **missing**; a source with two rows is
  reported **duplicated**; a row naming a source that was never transported is
  reported **unknown** and is not counted toward coverage;
- a row whose source hash or quote does not match what was actually transported
  is degraded to `unknown` with the reason recorded;
- a row that leaves any sealed anchor out of **all four**
  verdict lists is degraded, and the reason names the exact ids it left out; so
  is a row that gives the same anchor two verdicts, or a verdict to an anchor
  that does not exist;
- `notInReachConstructs` is the cheapest verdict to give, so it is fail-closed
  in every direction. The universe is the wrapper's full sealed enumeration,
  not the model's; `scope` names only the applicable kinds. Anchors of every
  other kind must still be accounted for, and may appear only in
  `notInReachConstructs`. An applicable anchor may be ruled out only with code
  evidence. A kind the wrapper does not enumerate cannot define a scope; an id
  repeated inside one list is refused rather than
  quietly deduplicated - including when the repeat is hidden inside overlapping
  ranges - because collapsing it would let a short list impersonate an exact
  cover;
- the row's `status` is **derived from the verdicts**: `unknown` if any anchor
  is undecided, else `violation` if any anchor violates, else `notApplicable`
  if none was weighed, else `compliant`. Where the model's own `status`
  disagrees, the anchors decide and the disagreement is recorded. This is what
  stops one chosen method standing in for a rule;
- a row that declares `scope: none` while constructs exist, or that puts every
  anchor in its scope out of reach, may only be `notApplicable` or `unknown` -
  a `compliant` row that weighed nothing is an answer about nothing;
- a row whose linked candidate is anchored outside every construct it called
  violating is degraded: a row about one place cannot account for a finding
  about another. The anchor may fall anywhere inside the construct's
  `line`..`endLine` span, because a comment about a multi-line call belongs on
  the offending argument rather than on the line the call opens on;
- a candidate whose rule has no row is reported as unaccounted.

Any of those makes the accounting incomplete, and the preview says so. It never
silently annotates and continues.

The accounting is deliberately powerless. It cannot create a finding, widen one,
or bypass cross-verification: only `candidates[]` produces comment text, and
every candidate still has to satisfy every rule it already did. A row that
claims a `violation` with no emitted candidate is recorded through the existing
`withheld` list under `accountedNotEmitted` - one channel, not two, because two
lists that both mean "nearly a finding" is where a later edit promotes one.
Sibling evidence describes unchanged code and can never be the subject of a
candidate or the anchor of a row.

Local practice does not repeal a transported rule. Code that breaks a rule its
unchanged neighbours also break is still a violation; what the precedent changes
is severity, confidence, and whether the finding is worth a comment - not the
row's status. Otherwise the most-broken rule in a repository is the one that
reports cleanest, which is the opposite of what an operator asked for when they
transported it.

The anchor ids are deterministic and are the wrapper's own: the changed files,
ordinally sorted, from the change set it delivered, and the changed constructs
enumerated from them. Pattern hints for particular rule shapes are deliberately
**not** generated. They would steer the model toward exactly the categories the
hint generator enumerates, so measured recall would become a property of that
generator rather than of the specialist - which is the opposite of calibration.
Construct enumeration is the boundary: it says a call spans four lines and its
last argument is positional; it never says that is wrong.

### One reading is not a verdict

A row's status is one model's reading of the frozen input. Replayed again, the
same rule can read differently. `tools/Compare-ReviewerReplayRuns.ps1` compares
sealed runs of an identical binding and collapses anything they disagree about
to `unknown`, withholding any candidate that not every run proposed. There is no
majority vote: see `docs/replay-snapshots.md`.