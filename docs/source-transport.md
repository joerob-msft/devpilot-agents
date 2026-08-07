# Sealed source transport

The reviewer's model is given **no tool that can read a file**. It is given the
file's bytes instead.

## Why

The reviewer originally told the model to call the host's repository file-read
tool for context around a hunk. On a real Azure DevOps MCP host that call is a
silent no-op. The server answers `tools/call` with a single embedded **resource**
content item whose payload is a base64 `blob`:

```json
{"content":[{"type":"resource","resource":{
  "blob":"<base64>","mimeType":"text/plain","uri":"/src/Foo/Bar.cs"}}]}
```

The wrapper's own decoder handles that shape correctly. A CLI model transcript
does not: binary resource payloads are not inlined, so the model receives an
**empty result** — no text, no error, and no way to tell "the file is empty" from
"the read failed". A live probe with only that tool available reported:

> `PROBE_READABLE: no` — "The tool returned no output at all — empty result with
> no content, no error message, and no text of any kind."

The remaining channel, the pull-request change-set tool with line content, is
one enormous tool result: 1.6 MB for a ten-file change. Most of it never reaches
the transcript, so coverage silently degrades to whatever fits.

The observable effect is the dangerous one. The model produces a confident
review — sometimes an approval — over files it never read, and nothing in the
artifact says so.

## What the wrapper does instead

For each bound PR the wrapper:

1. reads authoritative paginated iteration identity, then reads the matching
   aggregate diff and derives, per changed path, the right-hand (post-change)
   line spans of every add and edit;
2. recovers a pure same-path edit whose aggregate blocks contain only
   context/deletes — the case ADO drops from the right-hand view — by reading the
   authoritative common-base and source versions the flat contract now pins and
   keeping only the spans that content difference proves;
3. expands each span by a policy context radius, clamps it to the file, and
   merges overlaps so no line travels twice;
4. reads each changed file's bytes itself at the exact 40-hex source commit,
   through the same validated resource contract it already uses;
5. cuts the merged spans into whole-line slices, hashing each one;
6. renders a **sealed block** — collision-checked fences, per-slice provenance
   JSON, and a leading content-accounting table;
7. refuses to review at all if coverage falls below the policy floor.

Nothing about the model's tool grant changes. It gains content, not capability.

## The accounting table

The block opens with every changed path and whether its source actually arrived:

| changed path | status | reason | lines delivered |
|---|---|---|---|
| `/src/Api/Handler.cs` | delivered | - | 12-58, 141-190 |
| `/src/Api/Generated.cs` | omitted | fileTooLarge | (none) |

`status` is `delivered`, `partial`, or `omitted`. `reason` comes from a closed
set: `budgetExhausted`, `sliceCountCapExceeded`, `fileTooLarge`, `notTextual`,
`decodeRejected`, `transportFailed`, `noChangedSpans`, `binaryNoText`,
`readerReportedNonTextUncorroborated`, `emptyFile`, `spansUnavailable`,
`fileCountCapExceeded`, `pathRejected`, `spanOutsideFile`, `unsafeSliceText`.

Those causes are told apart at the reader seam, before the strict decoder runs.
The decoder's job is safety and it refuses everything it dislikes the same way,
so letting it go first made a binary file, an oversized file and a genuine
transport fault all arrive as `transportFailed` — which sends an operator
hunting a transport bug instead of raising a cap. MIME type and decoded size are
now read structurally and judged against policy first; only content policy would
accept reaches the decoder, and only the decoder's own refusals become
`decodeRejected`. Nothing about its strictness changes.

**A change set with no right-hand lines is not a failure — but only the pull
request may say so.** Delete-only and rename-only changes legitimately
have paths and no changed lines: those paths are counted apart and are **excluded
from the coverage denominator**, because the change set itself says there is no
source for the transport to deliver and they therefore cannot be uncovered. A
binary or an empty file is *not* in that category — only the reader says those
hold nothing, so they stay counted; see the denominator rule below. Leaving
deletes in meant a pull request that edited two files and deleted four scored
33% and was never reviewed — on every cycle, forever — though every changed
hunk in it had arrived. A change set that is nothing but deletes is reviewable
on the diff alone; a file that does carry changed lines and did not arrive
still fails the gate.

What decides which case a spanless path is, is the change set's own `changeType`
for that path — never the absence of parsed spans. Inferring the first from the
second is a fail-open with a large blast radius: any condition that costs the
line-diff blocks (a host change, a serialization change, a parser regression)
makes *every edited file* look like a delete, and excluding deletes from the
denominator then turns the loud refusal this layer exists to produce into a
silent 100% pass over files nobody read. So a spanless path whose declared change
kind carries content is read anyway, and what comes back decides:

| what the read says | reason | in the denominator? |
|---|---|---|
| zero bytes | `emptyFile` | **yes** — a zero-length payload is the host's claim too |
| not a text MIME type, and the path's own extension agrees | `binaryNoText` | **yes** — counted, but not charged against the ceiling |
| not a text MIME type, and the path looks like ordinary source | `readerReportedNonTextUncorroborated` | **yes** — counted *and* charged |
| a length that is not decodable | `decodeRejected` | **yes** — a malformed payload, not an oversized one |
| real text content | `spansUnavailable` | **yes** — its diff was lost |
| unreadable | `transportFailed` | **yes** |

Recovery is deliberately narrower than this spanless classification. It runs only
for a pure `edit` on the same path when the aggregate entry supplies at least one
well-formed delete block, optional context blocks, and no right-hand block. The
delete-block count is retained as independent evidence: requested-span accounting
uses at least that count, so a shorter recovered hunk list cannot award itself
100% coverage. Adds, deletes, any rename mixture, context-only/empty/malformed
block sets, ordinary diffs, binary/empty/oversized/decode-rejected content,
missing versions, equal versions, stale identity, and work over the
request/line/matrix/hunk caps remain unrecovered. The source read is cached and
reused by normal slicing. Ordinary missing-path/read errors disable recovery for
that file; a session-fatal transport failure still propagates. Every unsuccessful
attempt retains the same closed-set omission reason and denominator treatment it
had before recovery.

Recovery additionally requires an authoritative binding to the configured
organization, project, repository ID, PR ID, exact iteration ID, source, target,
and common-base commit. When the MCP server exposes the authoritative flat
paginated `get_changes` contract (microsoft/azure-devops-mcp PR #1499, head
`276d802a53`), the wrapper detects it via `tools/list` input-schema inspection.
Detection is structured, not a boolean: the `repo_pull_request` input schema must
expose `get_changes` in the `action` enum together with `iterationId`, pagination
controls `top` and `skip`, and Agency's existing aggregate-span inputs
`includeDiffs` and `includeLineContent`. A successful probe yields a
structured capability (bounded `PageSize` and `ChangeLimit`) rather than a flag.
The detection is strict: any missing property, malformed schema, null response,
or `tools/list` error causes the wrapper to fall back to legacy `get_changes`
behavior with recovery dormant and its body semantically unchanged. The probe
never touches the shared ordinary-transport session: it runs on a dedicated,
short-lived repos-only MCP session that is always closed, and its result
(including a null) is cached on the shared session so it is computed at most once.
The public local PR #1499 server intentionally exposes identity-only changes and
does not advertise aggregate line diffs, so that schema alone remains dormant:
hosted Agency must deploy the identity fields additively on its existing diff
response before recovery activates.

When the flat contract is detected the wrapper drives a single bounded paginator.
Each page is a flat record that carries its own full identity, and the wrapper
binds every field strictly before trusting the page:

1. **Per-page identity** — `iterationId` (positive), `iterationReason`
   (`{ value, names, unrecognizedBits }`, where a null value forces empty names
   and zero unrecognized bits), the exact lowercase 40-hex `commonRefCommit`,
   `sourceRefCommit`, and `targetRefCommit`, and a retarget pair
   (`oldTargetRefName`/`newTargetRefName`) that is either both-null or both
   well-formed `refs/heads/*`. `commitsTruncated` is retained as identity metadata
   (the exact common/source/target commits remain available), and the
   continuation fields `hasMoreChanges`/`nextSkip`/`nextTop` must be internally
   consistent (a terminal page pins both continuation cursors to zero; a
   continuing page advances `nextSkip` by exactly the delivered count and keeps
   `nextTop` within the server's 1000-entry bound).
2. **Bounded pagination** — the first page is fetched with `top` clamped to 200,
   `skip = 0`, and no explicit iteration (any iteration is accepted to *discover*
   the identity). Every subsequent page pins the discovered `iterationId`
   explicitly and must match the first page's identity exactly; a page whose
   identity differs fails closed as mixed-identity. Advertised page sizes are
   capped to the 1000 hard ceiling on the wire, a page returning more than the
   requested `top` is refused, and a change set that would exceed the bounded
   total of 1000 fails closed rather than reading forever. The source commit
   discovered on the first page must equal the pinned source commit.
3. **Bracketed aggregate read and final latest re-read** — only after the first
   complete identity read does the orchestrator request aggregate spans. After
   all content and report reads it re-reads the latest iteration whole with the
   same bounded page/limit and fails closed on any movement: a force push (new
   iteration), a rebase (common commit moved), a retarget (target commit or refs
   changed), a reason change, or any change to the aggregated change list. The
   pre-read and post-read pagination digests must be equal.

The identity paginator supplements rather than replaces the existing aggregate
diff read: its complete path/original-path/change-type digest must exactly match
the aggregate response. The aggregate response remains the authoritative source
of ordinary Add/Edit right-hand blocks, which are delivered with
`spanBasis = "changeSet"` and take no recovery reads. Every raw aggregate path,
including a path rejected by the safe-path grammar, remains in the coverage
denominator (`pathRejected` rather than silently disappearing). Recovery runs
only for the degenerate context/delete-only case on a pure same-path edit carrying
at least one delete block: the wrapper reads the authoritative `commonRefCommit`
base version and the `sourceRefCommit` version (which must equal the pinned source
commit) and keeps only the right-hand spans that common→source content difference
proves, presented as `spanBasis = "recovered"`. Add/delete/rename/mixed changes,
an edit whose `originalPath` differs, and identical common/source content are
never recovered. Incomplete pagination is rejected before any content read begins.
The coverage gate, caps, and denominator rules are unchanged.

Every file carries a versioned `spanBasis`: `changeSet` for ADO-declared
right-hand blocks and `recovered` for deterministic common-base/source evidence.
The basis is present in the model-facing accounting row, every slice's provenance,
the persisted coverage record, preview/cycle metadata, and therefore artifact
digests. Recovery attempted/recovered/evidence counts, the exact common-base
commit, and the iteration ID are bounded accounting fields rather than hidden
implementation details.

Span recovery is available only where hosted Agency exposes PR #1499's flat
paginated identity fields additively with its aggregate line-diff inputs.
Against the public identity-only server, any older server, or a partial
deployment, the structured probe fails, recovery stays dormant, and the wrapper
reviews exactly as it did before — the degenerate pure-edit case is simply left
uncovered rather than recovered.

`binaryNoText` and `readerReportedNonTextUncorroborated` are the same reader
answer split by whether anyone else corroborates it. When the change set's own
path ends in a non-text extension, two independent parties agree and the path is
a plain binary. When only the host says it — the pull request calls the path
`/src/Handler.cs` — the claim rests entirely on the party this layer exists to
distrust, so it gets its own reason. The model-facing block then names it
explicitly: the repository host alone reported it non-text, no source was
delivered, the path may not be reviewed or cleared, and the share of a change set
that may be set aside this way is bounded. Neither reason is ever presented to a
model as "nothing to check" — only the pull request's own word is.

`notTextual` is a third thing again, and is deliberately separate from both: it
is emitted for a path the change set DID diff as text — it has added and edited
lines — which the wrapper's MIME allowlist then refused to fetch. That is an
unread file, not an unreadable one, so it stays source-bearing and fails the gate
if it is not delivered.

A reader may only author the conclusions a reader is entitled to reach:
`notTextual`, `emptyFile`, `decodeRejected`, `fileTooLarge` and
`transportFailed`. Everything else in the closed set is a conclusion this layer
draws for itself, and a reader returning one is refused rather than believed.
`noChangedSpans` is the sharp case — it is the one reason the model is told means
"the pull request itself says there is nothing here", so a host able to return it
could hand the model a settled "nothing to check" over any file it liked, on a
passing review.

Emptiness is decided on the reported byte length, not on whitespace: a file of
blank lines has content a reviewer could be shown. A reader that reports no byte
length at all cannot excuse a path by omission. Every excusing decision records
the MIME type, byte length and hash it was made on, plus **what said so** —
`changeSet` or `reader` — so an operator auditing why a path left the denominator
has the evidence in the coverage record.

That last distinction is load-bearing. A change set that declares every path a
delete is *vacuously* covered and is reviewed on its diff. A change set that only
looks source-free because the reader called every path's bytes non-text is **not**:
that is the same host whose misbehaviour lost the line-diff blocks in the first
place, so those paths never leave the denominator, and the gate refuses them at
0% under `sourceCoverageEmpty` rather than passing at a vacuous 100%.

### Only the change set may shrink the coverage denominator

A path leaves the coverage denominator **only** when the pull request itself says
it holds no added or edited text — a delete or a rename. That statement is the
PR's own; it is true for everyone, and nothing the host does can manufacture it.

A path that merely came back unreadable — the host said its bytes are not text,
or its length was not decodable, or its hunk list never arrived — stays counted.
Its source was not established, and that is not the same as there being nothing
to establish. Letting the reader shrink the denominator is how one delivered file
beside nine the host mislabelled reported **100%**: the number now reads **10%**,
which is what actually happened.

`readerExcusedShareExceeded` remains as a second, independent refusal when
uncorroborated reader excusals exceed `max(2, 50%)` of the distinct contested
paths, so a mislabelling host is refused on two counts rather than one. Both
bounds are code constants, not policy keys.

**The cost is deliberate.** A pull request that adds files the host reports as
non-text scores against them, because from this side "an icon" and "a source file
the host is lying about" are the same answer, and only one of those may be
believed. One text file plus three icons is refused; seven text files plus three
icons is reviewed. If a repository needs asset-heavy pull requests reviewed, that
is a `minDeliveredFilePercent` decision made with the trade in view, not
something this layer should infer.

The model is never told a reader-excused path has nothing to check. Exactly one
reason — `noChangedSpans` — is presented that way, and every other omission
reason is described as a path whose source content could not be established,
which the model must treat as unread.

Emptying the denominator was the extreme case; shrinking it was the same attack
at lower volume. Nine paths a host mislabelled as non-text, beside one file that
really was delivered, *used to* leave one source-bearing file of which one was
covered — a clean **100%** over a change set the model had seen a tenth of, with
every percentage floor satisfied. That is the shape the cap below was added for.
The denominator rule above now refuses it independently: the same change set
reports **10%** and fails the coverage floor as well as the cap.

So reader-derived excusal is capped — but only the part of it nobody else
corroborates. When the reader says a path's bytes are not text **and the change
set's own path for it ends in a non-text extension**, two independent parties
agree and the excusal is free. When the reader alone says that about
`/src/Handler.cs`, only the untrusted party is talking, and that is what the cap
governs: at most `max(2, 50% of the distinct paths whose text status is
contested)` uncorroborated reader excusals, after which the gate refuses with
`readerExcusedShareExceeded` rather than dividing by a number the host chose.

Two details of that arithmetic are load-bearing:

- The share is measured against the **distinct** paths whose text status is
  actually contested — every path that carries source, plus every reader excusal
  the path name does not corroborate, counted once each and case-insensitively,
  with malformed paths and paths dropped by the file cap excluded (neither was
  ever read, so neither is contested). Every looser denominator has been a
  padding vector: all changed paths let a bulk move buy allowance; all
  source-capable paths let *icons* buy it, two assets per free mislabelled source
  file; counting change-set *entries* let a repeated `item.path` buy it; and an
  ordinal comparer let eight case-variant spellings of one path buy it on a
  case-insensitive host. The charge is still counted per entry, so a duplicated
  mislabelled path over-charges — the safe direction.
- Unknown and extensionless paths count as **uncorroborated**, because the
  conservative direction is the one that keeps a path counted.

Both bounds are **code constants, not policy keys** — a consumer config able to
widen them could re-open the hole they close, and a policy naming one is rejected
as unknown.

Worked examples, all with the shipped policy. Note the coverage percentage counts
every path the change set did not itself declare source-free, so a reader excusal
lowers it:

| change set | reader-excused | of those charged | allowance | file % | outcome |
|---|---|---|---|---|---|
| 1 edited file + 3 `.png` | 3 | 0 | 2 | 25 | refused — below the coverage floor |
| 1 edited file + 40 `.png` | 40 | 0 | 2 | 2 | refused |
| 7 edited files + 3 `.png` | 3 | 0 | 3 | 70 | reviewed |
| 6 edited files + 4 `.png` | 4 | 0 | 3 | 60 | reviewed — exactly on the floor |
| 1 delivered + 9 mislabelled `.cs` | 9 | 9 | 5 | 10 | refused, `sourceCoverageBelowPercentFloor` and `readerExcusedShareExceeded` |
| the same padded with 8 deletes + 8 renames | 9 | 9 | 5 | 10 | refused — padding buys nothing |
| the same padded with 8 `.png` | 17 | 9 | 5 | 5 | refused — nor does asset padding |
| 5 delivered + 5 mislabelled `.cs` | 5 | 5 | 5 | 50 | refused — at the allowance, under the floor |
| 4 delivered + 6 mislabelled `.cs` | 6 | 6 | 5 | 40 | refused |
| 9 change-set deletes + 1 delivered | 0 | 0 | 2 | 100 | reviewed — the change set's own statement |
| 0 delivered + 4 reader-excused | 4 | any | 2 | 0 | refused, `sourceCoverageEmpty` |

So an asset-heavy pull request is refused unless its text files alone clear the
coverage floor: from this side an icon and a source file the host is lying about
are the same answer, and only one of them may be believed. An added empty file
counts against coverage for the same reason — a zero-length payload is a claim by
the same host that supplies the MIME type, and forging it is no harder.

Paths excused either way stay listed in the accounting table and are counted
separately in the coverage record (`changeSetExcusedFileCount`,
`readerExcusedFileCount`, `readerExcusedUncorroboratedCount`,
`readerNonTextUncorroboratedCount`, `readerExcusedAllowance`), and the human
preview states the two kinds on separate
lines — reader-excused ones as counted in the percentage and among the files
nobody read — so a reader can see which claim came from where.

The kinds treated as carrying no content are `delete`, `rename`, `sourcerename`,
`targetrename`, `encoding`, `lock` and `property`. A path is excused only when
*every* one of its declared kinds is in that set; anything else — `add`, `edit`,
`undelete`, `branch`, `merge`, `rollback`, or any value the layer does not
recognize, including a missing one and Azure DevOps' `None`/`0` — is treated as
content-bearing, because that is the direction that fails closed. Integer
`changeType` values are decoded with Azure DevOps' own `VersionControlChangeType`
bits and every bit is asserted in the tests, since a shifted bit would silently
turn `Undelete` into `Delete` and excuse a restored file unread. Where a change
set carries more than one entry for a path, the kinds are unioned, so a trailing
`Delete` row cannot erase an earlier `Edit`.

That read costs one whole-file fetch per spanless content-declaring path, so it
is capped at 16 per pull request — but the budget is spent only on reads that
come back **content-bearing**. The case worth bounding is a response that lost
every line-diff block, where every probe returns real text and the coverage floor
is going to refuse the pull request anyway; a pull request that adds forty icons
returns forty non-text answers and spends no budget. Past the cap a path is
counted uncovered without being read, which is the fail-closed direction. All
reads remain bounded by `maxFiles` and `maxFetchBytesPerFile`.

One consequence is worth stating plainly. A pull request consisting of **nothing
but** assets — an icon set, a fixture directory, a localization bundle — leaves
every path excused on the reader's say-so, delivers no source at all, and is
therefore refused at 0% under `sourceCoverageEmpty` rather than reviewed. That is
deliberate and it is the fail-closed side of the rule above: the same shape is
what a host that lost every line-diff block and mislabelled every MIME type
produces, and nothing in the response distinguishes them. An operator reading the
log sees a coverage figure of 0% naming every path, rather than a transport
fault, and a single text file anywhere in the change set is enough to make the
pull request reviewable again.

No hunk is ever invented for these paths. The pull request reported no hunks for
them, so they contribute nothing to the span numerator or denominator — the
file-level floor is what carries them — and the block's sentence about "changed
hunk(s) as the pull request reports them" stays literally true.

The cross-check between the two extractions only calls mis-parse when a
permissive independent scan finds right-hand-bearing line blocks in the response
and the structured extractor still produced none. The two share one
admissibility rule and differ in exactly one deliberate case: a `changeType` the
extractor cannot read is admissible to the scan, because a block the scan sees
and the extractor does not is the mis-parse it exists to catch.

Both prompts bind the model to that table: it may not report on, clear, or claim
to have reviewed an `omitted` path, and must describe a `partial` path as
partially read. **Exactly one** reason is an exception, because it is the only
one that is not a gap in what the model was given: `noChangedSpans`, the pull
request's own statement that it deleted or renamed the path. Every other reason —
`binaryNoText`, `readerReportedNonTextUncorroborated`, `emptyFile`, `notTextual`,
`fileTooLarge`, `spansUnavailable`,
`decodeRejected`, `transportFailed` — means the source content could not be
established: a file the model has not read and that nobody has confirmed is
empty. That sentence is **generated from** the closed set in code rather than
written beside it, so the prose the model obeys cannot drift from the rule the
gate applies. That is what stops structural metadata being mistaken for source
text.

The table is rendered whenever there is any changed path to account for, even
when nothing at all was delivered. Suppressing it at zero coverage would leave
the model with no source *and* no statement that source is missing, which is
precisely the condition this layer exists to make impossible.

The block also names its own fence token and states that everything between a
`<TOKEN> BEGIN` and its matching `<TOKEN> END` is quoted file bytes. Slice text
is attacker-controlled, so without that sentence a PR could embed a second,
forged accounting table and the model would have no rule telling it which one is
real. A changed path carrying `|`, a backtick, `<` or `>` is refused outright
(`pathRejected`) rather than rendered, because those are exactly the characters
that would forge extra cells in the table.

## The fail-closed floor

`source/v1/policy.json` carries `minDeliveredFiles`, `minDeliveredFilePercent`
and `minDeliveredSpanPercent`. `Test-ReviewerSourceCoverageGate` turns the
report into a pass/fail with explicit reason codes:

| reason code | meaning |
|---|---|
| `sourceCoverageEmpty` | not one changed file's source reached the model |
| `sourceCoverageBelowFileFloor` | fewer **fully** delivered files than the policy floor |
| `sourceCoverageBelowPercentFloor` | covered share of source-bearing files below the policy percentage |
| `sourceCoverageBelowSpanFloor` | delivered share of changed hunks below the policy percentage |
| `sourceCoverageUnknown` | the change set could not be established at all |
| `readerExcusedShareExceeded` | more paths were excused on the reader's unsupported word than the code ceiling allows |

Every percentage is measured against the changed files the **pull request itself**
did not declare source-free. A change set with no such files at all passes with
no reason codes — there was nothing to deliver, which is a different thing from
having failed to deliver something. A change set the reader alone calls
source-free keeps every path counted and is refused at 0%.

The span floor exists because a file-level count alone can be gamed by
arithmetic: a change set where every file delivered one region out of twenty-four
would otherwise score 100%. The file floor counts only **fully** delivered
files for the same reason — a partially delivered file is one the model has seen
part of, which is not the same as one it has read.

Both span numbers are counted in the pull request's **own hunks**, not in the
merged spans the transport happens to cut. A raw hunk counts as delivered when a
delivered slice fully contains it. That keeps the units honest in both
directions: expanding the context radius merges slices together without ever
moving the denominator, and an unread file contributes its hunks to the
denominator rather than being quietly excluded.

The span ratio has one deliberate blind spot, and the block states it. A path
whose hunk list never arrived (`spansUnavailable`) contributes to neither side —
there is no honest hunk count to contribute, and inventing one would put hunks
into a sentence that attributes them to the pull request. The count of such paths
travels beside the ratio instead, and the sentence says the ratio covers only the
files whose hunk list the pull request reported. The file-level floor is what
catches them.

A PR that trips any of these is **not reviewed**. No preview, no comments, no
vote — the cycle records the reason and moves on. An unperformed review that
says so is strictly better than a clean-looking one that is silent about it.

**What the floors compose to is weaker than any of them alone**, and it is worth
stating plainly rather than leaving a reader to infer it. The reader-excusal
allowance says at most half the contested paths may be excused on the host's
unsupported word; the file floor says at least 60% of source-bearing files must
arrive whole. Both can be satisfied at once by a change set that is half
mislabelled and 40% simply undelivered: 18 delivered files, 12 that carry source
and did not arrive, and 30 mislabelled ones passes every rule with the model
holding **18 of 60 changed paths**. Nothing there is a defect — each path is
accounted honestly and the block names every one the model did not get — but the
guarantee is "no single failure mode may exceed its own floor", not "the model
saw 60% of the change". Raise `minDeliveredFilePercent` if a repository needs a
tighter composed bound.

The preview a human reads carries the same numbers, and names the changed files
whose source never arrived, so "no findings" can never be read as "every file
was checked".

## Sibling evidence

The convention specialist may not report an **adoption-dependent** convention —
a test-ownership attribute, say — without evidence that the repository's
unchanged code already follows it. A transport that delivers only changed
regions therefore starves the rule it was meant to enable.

That is not hypothetical. A live run found missing ownership attributes at the
right lines in two test files and withheld every one of them as
`missingSiblingEvidence`, because the unchanged methods that carry the attribute
sat outside the delivered spans. The specialist was right to refuse; it had been
given no way to be right any other way.

So each delivered file also carries up to `siblingContextSlices` slices of
**unchanged** text, taken from the gaps immediately adjacent to the delivered
spans — the members that neighbour a change are the ones whose conventions it
should match. Selection is deterministic and semantically blind: gaps in line
order, nearest lines first, capped.

Sibling slices are hashed and fenced exactly like changed ones, carry
`"kind":"sibling"` in their provenance, and are cut only **after** every changed
span has had its chance at the budget, so unchanged text can never displace the
change within a file. The block tells the model what they are: evidence of
established practice, never part of the pull request, and never something to
report a finding on.

They also draw on a **separate whole-pull-request budget**, `maxTotalSiblingBytes`.
Ordering alone was not enough: when both drew on `maxTotalSliceBytes`, the
sibling context attached to the first file could consume the allowance the tenth
file's changed hunks needed, so switching sibling evidence on quietly lowered
changed-source coverage somewhere else in the same pull request — and could push
it under the fail-closed floor. On the pinned ten-file snapshot the split moved
changed-hunk coverage from 29/30 to 30/30.

The two figures are **disjoint**. `totalSliceBytes` counts changed bytes only —
it is named after `maxTotalSliceBytes` and must respect it — `totalSiblingBytes`
counts sibling bytes only, and `totalDeliveredBytes` is their sum. The policy
validator also refuses a pair whose sum could not fit the sealed block's
rendered-byte bound.

Nothing about sibling context can move a coverage number. `RawRequestedSpanCount`
counts raw hunks; `DeliveredRawSpanCount` is measured against the **changed**
slice list only; and a file's `delivered`/`partial` status is decided before any
sibling text is cut. Turning sibling context on or off delivers byte-identical
changed slices.

Setting `siblingContextSlices` or `maxTotalSiblingBytes` to zero disables this and
restores the starved behaviour.

## Budgets

Defaults are calibrated against a real ten-file change: 30 lines of context,
32 KB of slices per file, 192 KB in total, and two 80-line sibling slices per
file. That change transported 10/10 files in 83,605 bytes of changed regions —
against 1.6 MB for the raw diff channel and 0 bytes for the file-read tool — and
147,583 bytes once sibling evidence is included.

| key | default | what it bounds |
|---|---|---|
| `contextRadiusLines` | 30 | unchanged lines kept on each side of a changed span |
| `maxFetchBytesPerFile` | 1048576 | largest file the wrapper will read; larger is `fileTooLarge` |
| `maxSliceBytesPerFile` | 32768 | delivered slice bytes for one file |
| `maxTotalSliceBytes` | 196608 | delivered CHANGED slice bytes for the whole PR |
| `maxSlicesPerFile` | 24 | slices for one file |
| `siblingContextSlices` | 2 | slices of UNCHANGED text delivered next to the change, per file |
| `siblingContextLines` | 80 | lines in each sibling slice |
| `maxTotalSiblingBytes` | 49152 | delivered SIBLING bytes for the whole PR, kept apart so evidence cannot starve the change |
| `maxFiles` | 60 | changed files **read** before the cap is accounted; a delete or rename is never read and never charged against it |

A slice that does not fit is **dropped whole**, never truncated, so a recorded
SHA-256 always covers exactly the lines it names. Slice hashes are computed over
**LF-normalized** text, while `fileSha256` is over the file's raw bytes; on a
CRLF file the two are therefore not derivable from one another.

## Two extractions, cross-checked

The changed-path list and the diff span map are parsed from the same response by
different code. They are cross-checked, and a disagreement is fatal. This is not
theoretical: the first live run of this layer collapsed all ten paths into one
space-joined string (a `,`-returned array wrapped in `@()`), which still looked
like a perfectly legal one-file change set. The only symptom was coverage
reading zero. The cross-check makes that class of mistake loud.

The pinned commit is re-read after the slices are cut. Spans come from the PR's
current iteration while bytes come from the pinned commit, so a push in between
would produce correct bytes at the wrong lines — hashed cleanly, with nothing to
notice it.

## Convention sources by section

The same size problem defeats convention routing. A real engineering-guidance
document runs to tens of kilobytes; a pack's budget is a few. Fetching it whole
either exceeds the per-source cap — failing the pack, so the rule silently never
reaches the reviewer — or consumes the entire budget for one file.

An authoritative source may therefore name a `section`: the exact ATX heading of
the governing rule.

```json
{
  "name": "acronym-casing",
  "organization": "contoso",
  "project": "ExampleProject",
  "repositoryId": "22222222-2222-2222-2222-222222222222",
  "path": "/documentation/Conventions/CodingStyle.md",
  "branch": "main",
  "section": "### Casing of acronyms in comments",
  "maxBytes": 2048
}
```

The wrapper fetches the document, cuts from that heading to the next heading at
the same or shallower level (so subsections travel with their parent), and
delivers only that. `maxBytes` then bounds the **delivered section**, not the
file. Provenance carries the section heading and its line range beside the
commit and the slice's own SHA-256, so an exact rule quote stays verifiable.

Fenced code blocks are tracked while scanning, and indented lines are ignored.
Guidance documents are full of shell, YAML and PowerShell samples whose comment
lines begin with `#`; read as headings, those would truncate the rule while the
cut still hashed cleanly — delivering the wrong rule with full provenance.

Matching is exact and case-sensitive. A near-miss is a hard failure, never an
approximation: silently delivering the wrong rule is worse than delivering none.

## When the marker itself is unusable

The model returns its result as a single-line JSON marker. A live run lost a
complete, correct review to one stray bracket in roughly four kilobytes of
hand-written single-line JSON. Two things address that, and neither loosens the
schema:

- duplicate marker occurrences are compared **canonically** rather than
  byte-for-byte, so a pretty-printed restatement alongside the required compact
  line is one result rather than a conflict — while two markers that genuinely
  disagree still fail closed;
- extraction is anchored to line starts, and occurrences are then filtered by
  the schema's exact-valued fields — the per-cycle nonce among them. The nonce
  is generated after the PR's content was authored, so a marker a PR author
  planted in a source file cannot carry it. That matters more now that the
  wrapper injects raw file lines into the model's context: without the filter,
  a source line reading `REVIEWER_RESULT_V1: {...}` that the model echoed while
  quoting evidence would be a conflicting second candidate and would veto its
  own review. Two nonce-matching markers that disagree still fail closed;
- a pass whose run was otherwise clean but whose marker was unusable is retried
  **once**, in a fresh session with a fresh nonce. A timeout, a nonzero exit, an
  environment fault, or a marker bound to the wrong PR is never retried.

## What this does not fix

- **It is still the model that reads.** Delivering the bytes proves the bytes
  arrived, not that they were understood.
- **One pull request cannot end a cycle.** An oversized model input fails that
  pass with a stated reason rather than throwing, and the per-pull-request
  review is isolated, so a PR that cannot be reviewed does not take the ones
  queued behind it with it. That failure is attributed to the pull request, so
  a change set too large to fit retires visibly through the attempts budget
  rather than being retried forever. What it never does is run the model anyway:
  below the coverage floor the review does not happen.
- **Coverage is measured in files, not in judgement.** A `delivered` file whose
  changed span is a one-line edit inside a 3,000-line class still gives the model
  only a local view.
- **A file larger than `maxFetchBytesPerFile` is reported, not read.** That is a
  deliberate refusal, and the accounting says so.
