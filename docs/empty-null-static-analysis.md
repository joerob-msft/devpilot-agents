# Empty-to-null static analysis

`tools/Find-PowerShellEmptyNullHazard.ps1` is a standalone PowerShell AST
analyzer for three recurring empty-output hazards:

| Rule | Reports |
|---|---|
| `PSEN001` | Bare command or pipeline output assigned to an explicitly typed array, or passed to a mandatory typed-array parameter declared in the analyzed files |
| `PSEN002` | An array subexpression that contains an explicit `$null` without a recognizable null-removing `Where-Object` filter |
| `PSEN003` | `.Sum` access on `Measure-Object -Sum` without a recognized default, enclosing non-empty count guard, or preceding terminating empty-count guard |

Run it over one file or a tree:

```powershell
./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse
./tools/Find-PowerShellEmptyNullHazard.ps1 -Path ./src -Recurse -OutputFormat Json
```

## Focused measurement

`tools/Test-PowerShellEmptyNullHazardAnalyzer.ps1` scores 15 labeled fixtures
and emits JSON counts for true positives, false positives, false negatives, and
true negatives. The checked-in corpus measures 7 TP, 0 FP, 0 FN, and 8 TN.
These are fixture-corpus results, not estimated production precision or recall.

The measurement supports using the analyzer as an in-place prevention check for
the represented syntax, initially in reporting mode. It does not justify a
repository-wide blocking gate yet. PowerShell has dynamic command resolution,
aliases, splatting, indirect invocation, and unconstrained output cardinality;
the analyzer only binds mandatory array parameters on functions visible in the
same analyzed input. Its guard recognition is intentionally limited to direct
count comparisons, `??` defaults, and direct terminating empty-count guards.
Additional real-code sampling and labeled counterexamples should precede a
blocking rollout.

## Repository-wide reporting measurement

The reporting-mode command above was also run over all of `src/`. It emitted 23
findings: 7 `PSEN001`, 14 `PSEN002`, and 2 `PSEN003`. A deterministic sample of
the first 12 findings in file/line/rule order was manually classified against
the surrounding implementation:

| Classification | Count | Representative evidence |
|---|---:|---|
| True positive | 1 | `ConventionPacks.ps1` reads `.Sum` from an empty-capable resolved-source list without a default |
| False positive | 8 | Preserved `return ,@(...)` output, string casts that eliminate null, predicate references to `$null`, and explicit non-empty guards |
| Unknown / intentional test construct | 3 | Adversarial fixture arrays deliberately containing `$null` and parser-shape probes |

This sample is useful for direction, not a statistical precision estimate:
only 12 of 23 reports were classified, selection was deterministic rather than
random, and dynamic output cardinality cannot always be proven statically.
The observed actionable precision among classified non-test reports was low
(1/9). In-place prevention is therefore viable only in reporting mode today;
making the rule blocking would create avoidable churn until command-return
contracts, explicit fixture scopes, and indirect count guards are modeled.
