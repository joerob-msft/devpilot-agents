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
