# Test-project class code-coverage rule

`test-class-code-coverage` is an allowlisted deterministic contextual rule.
It requires every changed C# class compiled by a proven test project to use
`System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute`.

Test-project membership is established from the nearest exact-head `.csproj`
using unconditional `IsTestProject=true` or a `Microsoft.NET.Test.Sdk`
package reference. `CoverageDisabled`, directory names, and class names are
not membership or exemption evidence. Conditional, ambiguous, explicitly
excluded, or unavailable project evidence is withheld as `unknown`.

The rule recognizes fully qualified, imported, and aliased framework
attributes. Assembly attributes and unrelated same-name attributes do not
satisfy the class requirement. Partial declarations without complete
cross-declaration evidence are withheld. Multiple definite missing classes
in one changed file are reported as one bounded grouped finding.
