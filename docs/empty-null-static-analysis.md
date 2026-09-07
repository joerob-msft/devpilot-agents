# Empty-to-null and boundary static analysis

`tools/Find-PowerShellEmptyNullHazard.ps1` is a standalone PowerShell AST analyzer.
It began as three rules for empty-output hazards and now carries eleven, split into
two families.


> **Scope.** What this does *not* prove is stated in
> [what the hardening layer does not prove](hardening-limitations.md).

## Empty-output hazards

| Rule | Reports |
|---|---|
| `PSEN001` | Bare command or pipeline output assigned to an explicitly typed array, or passed to a mandatory typed-array parameter declared in the analyzed files |
| `PSEN002` | An array subexpression that contains an explicit `$null` without a recognizable null-removing `Where-Object` filter |
| `PSEN003` | `.Sum` access on `Measure-Object -Sum` without a recognized default, enclosing non-empty count guard, or preceding terminating empty-count guard |

## Boundary hazards

These rules describe a collection, a closure, or a serialized contract changing shape as it
crosses a call, capture, or file boundary. Each one was written against an escape recorded
in [`escape-ledger.md`](escape-ledger.md).

| Rule | Reports | Escape it encodes |
|---|---|---|
| `PSEN004` | A function returns a locally constructed .NET collection bare, so PowerShell enumerates it and an empty collection becomes `$null` at the call site | `ESC-0001`, `ESC-0005` |
| `PSEN005` | `.Count`/`.Length` or an index taken directly on an unconstrained parenthesized command or pipeline expression | cardinality read off an unknown result |
| `PSEN006` | A script block references an unqualified variable that the same file assigns at script scope, so the captured value depends on ambient state | `ESC-0006`, `ESC-0008` |
| `PSEN007` | `ConvertTo-Json` without an explicit `-Depth`, leaving contract depth to the host default | implicit serialized depth |
| `PSEN008` | A `ConvertTo-Json` result written to a file without an explicit `-Compress` decision, leaving the on-disk form implicit | implicit serialized form |
| `PSEN009` | A non-preserved command result is assigned and later counted or indexed, so a single result flattens to a scalar | `ESC-0003`, `ESC-0004` |
| `PSEN010` | A `.GetNewClosure()` block calls a function defined in the analyzed files by name — `GetNewClosure` captures variables, not function definitions | `ESC-0006`, `ESC-0007` |
| `PSEN011` | `@(...)` wraps a call to a function that deliberately protects its collection return, nesting it as one element instead of flattening it | `ESC-0002`, `ESC-0012` |

`PSEN005`, `PSEN009`, and `PSEN011` share a notion of a *protected return*: a function whose
body emits its collection with `Write-Output -NoEnumerate` or `return ,$x`. Counting such a
call is safe and is not reported; wrapping it in `@(...)` is the `PSEN011` hazard.

A function with several exits needs two different answers, so the analyzer computes both:

* **any** exit protected — enough for `PSEN011`, because one nesting return is one nesting
  bug;
* **every** exit protected or provably scalar — required before `PSEN005` and `PSEN009` will
  stop reporting a call site, because a single unprotected exit is enough to collapse.

A mixed function therefore keeps its `PSEN011` finding *and* loses its counting exemption,
which is the conservative answer in both directions. "Provably scalar" is a deliberately
narrow allow-list — literals, strings, hashtables, scriptblocks, `$null`/`$true`/`$false`,
and type conversions to non-array, non-enumerating types. Anything the analyzer cannot
classify counts as a collection-bearing exit, including a return whose pipeline has more
than one element (`return $items | Sort-Object` enumerates) and a cast to an enumerating
type (`[List[object]]$x` ends in `]` but not `[]`, and it enumerates on return exactly as an
array does). Counting an unrecognised exit as *nothing* would let one protected exit buy the
exemption for a whole function, which is the escape shape these rules exist to catch.

Exemption and nesting are resolved per file, and separately, because they fail in opposite
directions:

* **Exemption** (`PSEN005`/`PSEN009` standing down) stays conservative. A call is exempt only
  when every definition of that name *in the calling file* is protected, or when the name is
  defined exactly once in the repository and that definition is protected. An ambiguous name
  earns nothing, because granting an exemption that was not earned hides a real collapse.
* **Nesting** (`PSEN011` firing) stays permissive. Any visible protected definition is enough.
  Withholding the nesting fact is what hides `PSEN011`, and a single unprotected one-line mock
  in a test file would otherwise disable the rule on every production call site of that name —
  the rule that found three of the live defects this branch fixes. An unnecessary `PSEN011` is
  a comment; a missing one is the bug class.

Seven function names in this repository are defined in more than one file with divergent
protection, so this split is load-bearing rather than theoretical. `Get-AgentCopilotArgs` is
the clearest case: the real definition in `src/DevPilot.AgentHarness/DevPilot.AgentHarness.psm1`
protects its single exit, while `tools/Test-ConventionSpecialist.ps1` defines an unprotected
one-line stub of the same name. The two `PSEN009` findings at its production call sites
(`src/Agents/review-handler/Start-ReviewHandlerAgent.ps1` and
`src/Agents/reviewer/Start-ReviewerAgent.ps1`) are baselined debt rather than defects: the
production code is correct, and the exemption is withheld only because the analyzer will not
guess which same-named definition a call resolves to. Removing them requires an import graph,
not a code change, so they are recorded as analyzer imprecision, not as a hazard.

Run it over one file or a tree, optionally filtering by rule:

```powershell
./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse
./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse -OutputFormat Json
./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse -RuleId PSEN004, PSEN011
```

## Focused measurement

Two fixture corpora measure the analyzer, and both are blocking.

`tools/Test-PowerShellEmptyNullHazardAnalyzer.ps1` scores 15 labeled fixtures for the
empty-output family: 7 TP, 0 FP, 0 FN, 8 TN.

`tools/Test-PowerShellBoundaryHardening.ps1` scores 27 labeled fixtures in
`tools/testdata/boundary-hardening-analyzer.fixtures.ps1` for the boundary family: 15 TP,
0 FP, 0 FN, 12 TN. Every boundary rule has at least one positive fixture proving it detects
its hazard and at least one negative fixture proving it ignores the corrected form. A rule
that stops detecting its own hazard, or starts reporting its own counterexample, fails the
check. A separate cross-file gate builds a producer, a consumer, and a same-named
unprotected mock in a temporary tree and requires identical `PSEN011` findings with and
without the mock, so a test-side stub cannot silence a rule on production code. Reverting
the exemption/nesting split makes that gate fail.

The same gate pins the one thing it cannot honestly assert away. Because the exemption rule
is deliberately conservative, a visible unprotected definition withdraws the exemption, so
an *unwrapped* call site of an otherwise-protected producer draws exactly one `PSEN009`
finding once the mock is present — and zero without it. That is accepted imprecision, and
it is the same mechanism as the two `Get-AgentCopilotArgs` entries in the baseline. The gate
records the count as an expectation rather than asserting it is zero: if the analyzer ever
becomes precise enough to drop it, the gate reports the change instead of passing silently.

Three of those fixtures exist specifically to pin the exemption rules above: a helper that
protects its return only on some paths must still be reported when its result is counted and
when it is wrapped, and a helper whose protection comes from a named parameter must not be
mistaken for a protected one.

These are fixture-corpus results, not estimated production precision or recall.

## Repository gate: new findings block, existing findings are debt

`tools/Test-PowerShellBoundaryHardening.ps1` also runs the analyzer over `src/` and `tools/`
and diffs the result against `tools/testdata/powershell-boundary-baseline.v1.json`. **Any
finding not in the baseline fails the build.** Existing findings are recorded as debt, not
approved: the baseline's `claim` field says `recorded-debt-not-approved-debt`.

Findings are fingerprinted by rule, repository-relative path, and whitespace-normalized
snippet rather than by line number, so the baseline survives unrelated edits above a finding
but does not survive a rewrite of the finding itself. Regenerating it is a deliberate,
reviewable act:

```powershell
./tools/Test-PowerShellBoundaryHardening.ps1 -UpdateBaseline
```

Current baseline: **442 findings across 372 fingerprints.**

| Rule | Baseline count | Status | Rationale |
|---|---:|---|---|
| `PSEN001` | 45 | debt | Dominated by preserved returns the analyzer cannot prove; each is debt until the producing function states its output contract |
| `PSEN002` | 38 | debt | Mostly adversarial fixtures and predicate references, kept as debt rather than rewritten mechanically |
| `PSEN003` | 3 | debt | Two of these were real incidents; the rest await an indirect-guard model |
| `PSEN004` | 0 | **clean** | This is the empty-fingerprint-set shape. The baseline is deliberately empty, so any new site is blocked outright |
| `PSEN005` | 43 | debt | The cheapest class to repair incrementally with `@()` |
| `PSEN006` | 1 | debt | Pending explicit capture |
| `PSEN007` | 41 | debt | Depth is implicit but stable at these sites; new contract writers must be explicit |
| `PSEN008` | 76 | debt | Same, for on-disk form |
| `PSEN009` | 167 | debt | The largest class; repairing it mechanically would risk the very defect the rule detects |
| `PSEN010` | 20 | debt | Closure capture; each site needs individual reasoning |
| `PSEN011` | 8 | debt | Recorded as `ESC-0012`. Eleven sites were found; three were live defects and were fixed, and the remaining eight are adjudicated site by site in the ledger |

`PSEN011` was not baselined in bulk. Each of the eleven sites was read against its producer
and its consumer: three were live defects and are fixed in this change, one is latent behind
a caller-side non-empty precondition, one is compensated by an explicit flattening step on
the consuming side, and six are test-harness assertions whose own assertions pin the shape.
That leaves eight in the baseline — two in production code and six in test harnesses. The
analyzer's own fixture corpus is excluded from the repository scan by name and is not part
of that count. The per-site adjudication is recorded in
[`escape-ledger.v2.json`](escape-ledger.v2.json) under `ESC-0012`, not summarised away here.

`PSEN004` at zero is the point of the gate. The rule was written from an escape that had
already merged; keeping its baseline empty means no *new instance the analyzer recognises*
can merge again. That is a narrower claim than "this escape shape cannot recur": the rule
matches a syntactic form, and a functionally identical collapse expressed another way — via
a pipeline, a splat, a member invocation, a nested scriptblock — is outside what it can
see. The baseline is a ratchet on recognised forms, not a proof of absence.

Fixture files are excluded from the repository scan — they exist to contain hazards, so
scanning them would record every deliberate counterexample as debt:

- `tools/testdata/empty-null-analyzer.fixtures.ps1`
- `tools/testdata/boundary-hardening-analyzer.fixtures.ps1`
- `tools/testdata/collection-escape-shapes.fixtures.ps1`

## Why the empty-output family is still reporting-only

The reporting-mode command was run over all of `src/` when the first three rules landed. It
emitted 23 findings: 7 `PSEN001`, 14 `PSEN002`, and 2 `PSEN003`. A deterministic sample of
the first 12 in file/line/rule order was manually classified:

| Classification | Count | Representative evidence |
|---|---:|---|
| True positive | 1 | `ConventionPacks.ps1` reads `.Sum` from an empty-capable resolved-source list without a default |
| False positive | 8 | Preserved `return ,@(...)` output, string casts that eliminate null, predicate references to `$null`, and explicit non-empty guards |
| Unknown / intentional test construct | 3 | Adversarial fixture arrays deliberately containing `$null` and parser-shape probes |

That sample is useful for direction, not as a precision estimate: only 12 of 23 reports were
classified and selection was deterministic rather than random. The observed actionable
precision among classified non-test reports was low.

The boundary gate is nonetheless blocking, because it does not assert that existing findings
are wrong — it asserts only that the population does not grow. A false positive costs one
`@(...)` or one baseline entry with a written rationale; a false negative costs another
merged escape.
