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

1. reads the change set **with** line diff blocks and derives, per changed path,
   the right-hand (post-change) line spans of every add and edit;
2. expands each span by a policy context radius, clamps it to the file, and
   merges overlaps so no line travels twice;
3. reads each changed file's bytes itself at the exact 40-hex source commit,
   through the same validated resource contract it already uses;
4. cuts the merged spans into whole-line slices, hashing each one;
5. renders a **sealed block** — collision-checked fences, per-slice provenance
   JSON, and a leading content-accounting table;
6. refuses to review at all if coverage falls below the policy floor.

Nothing about the model's tool grant changes. It gains content, not capability.

## The accounting table

The block opens with every changed path and whether its source actually arrived:

| changed path | status | reason | lines delivered |
|---|---|---|---|
| `/src/Api/Handler.cs` | delivered | - | 12-58, 141-190 |
| `/src/Api/Generated.cs` | omitted | fileTooLarge | (none) |

`status` is `delivered`, `partial`, or `omitted`. `reason` comes from a closed
set: `budgetExhausted`, `sliceCountCapExceeded`, `fileTooLarge`, `notTextual`,
`transportFailed`, `noChangedSpans`, `fileCountCapExceeded`, `pathRejected`,
`spanOutsideFile`, `unsafeSliceText`.

Both prompts bind the model to that table: it may not report on, clear, or claim
to have reviewed an `omitted` path, and must describe a `partial` path as
partially read. That is what stops structural metadata being mistaken for source
text — the model is told, in the same document, exactly what it does not have.

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
| `sourceCoverageBelowPercentFloor` | covered share of files below the policy percentage |
| `sourceCoverageBelowSpanFloor` | delivered share of changed regions below the policy percentage |
| `sourceCoverageUnknown` | the change set could not be established at all |

The span floor exists because a file-level count alone can be gamed by
arithmetic: a change set where every file delivered one region out of twenty-four
would otherwise score 100%. The file floor counts only **fully** delivered
files for the same reason — a partially delivered file is one the model has seen
part of, which is not the same as one it has read.

A PR that trips any of these is **not reviewed**. No preview, no comments, no
vote — the cycle records the reason and moves on. An unperformed review that
says so is strictly better than a clean-looking one that is silent about it.

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
change. The block tells the model what they are: evidence of established
practice, never part of the pull request, and never something to report a
finding on.

Setting `siblingContextSlices` to zero disables this and restores the starved
behaviour.

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
| `maxTotalSliceBytes` | 196608 | delivered slice bytes for the whole PR |
| `maxSlicesPerFile` | 24 | slices for one file |
| `siblingContextSlices` | 2 | slices of UNCHANGED text delivered next to the change, per file |
| `siblingContextLines` | 80 | lines in each sibling slice |
| `maxFiles` | 60 | changed files considered before the cap is accounted |

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
- **Coverage is measured in files, not in judgement.** A `delivered` file whose
  changed span is a one-line edit inside a 3,000-line class still gives the model
  only a local view.
- **A file larger than `maxFetchBytesPerFile` is reported, not read.** That is a
  deliberate refusal, and the accounting says so.
