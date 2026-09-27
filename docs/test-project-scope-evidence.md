# Dormant all-class test-project scope

The existing `bpm-test-class-coverage@1` and
`bpm-redundant-method-coverage@1` rules remain MSTest `[TestClass]`-only.
Their pinned local policy text, configuration, and posting permissions are
unchanged. The parser and read-only dispatcher can also recognize the
**dormant** `@2` counterparts: every changed C# class declaration in a
confirmed test project needs its own class-level coverage exclusion, including
fixture, helper, and nested classes. Changed stand-alone method-level coverage
exclusions in any excluded class are grouped into one finding per containing
class, without requiring `[TestMethod]`. Missing exclusions on partial
declarations and uncertain attribute resolution remain unknown. Changed
method bodies do not establish a changed class declaration or attribute.

The current Changes provider returns changed-file blobs and exact changed
spans, **not** project ownership or evaluated test-project identity. Thus
`@2` is not in the accepted rule registry or any configuration, and the
existing provider cannot supply a usable all-class project scope. Its
dispatcher path requires `evaluationFiles[n].projectEvidence` with this
bounded in-memory shape:

```json
{
  "schemaVersion": 1,
  "kind": "source-bound-evaluated-project-graph-v1",
  "complete": true,
  "repositoryId": "<bound repository GUID>",
  "sourceCommit": "<40-hex current source head>",
  "path": "/exact/changed/File.cs",
  "objectId": "<40-hex changed-file blob ID>",
  "projects": [
    {
      "path": "/exact/owning/Project.csproj",
      "objectId": "<40-hex project blob ID at source head>",
      "compileIncluded": true,
      "isTestProject": true
    }
  ]
}
```

This is an **attestation contract**, not a path or name heuristic: a later
trusted, bounded, read-only intake/provider integration must enumerate *all*
projects compiling the exact changed file at the pinned source commit,
verify the changed-file and project blobs at that commit, evaluate the
project graph (including imports, conditions, and compile include/exclude
rules), and establish each project's effective `IsTestProject` property.
The provider must prove completeness of the owning-project set before setting
`complete: true`. A bare project name, directory prefix, `Tests.cs` name,
MSTest attribute, SDK reference, or unevaluated `.csproj` text does not
establish this identity. The dispatcher checks the attestation's shape and
source/repository/path/blob binding but cannot independently re-evaluate
MSBuild from this envelope.

Absent, incomplete, stale, contradictory, malformed, or duplicate membership
is `test-project-identity-unknown`, not a clean result. A source file in
multiple projects is test-scoped only if **all** confirmed owners are test
projects; mixed test/product ownership is unknown. Confirmed product-only
membership is skipped for these `@2` rules. An actionable construct identity
also includes a digest of its project attestation, without persisting raw
project graph or source content.

Before activation, a separate layer must add an approved, immutable,
versioned `@2` policy/capability binding and intake evidence acquisition,
including the new proof in the read-only source-head checks. No unmerged
external document or current `@1` local policy is silently treated as
authorization for all-class review. This layer does not enable an `@2` rule,
change signing, deploy a task, or post any comment.
