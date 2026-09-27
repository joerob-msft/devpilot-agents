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

By default, Changes returns changed-file blobs and exact changed spans
without project identity. The optional read-only project evidence path
supplies evaluated ownership only when the complete graph can be attested.
`@2` remains outside the accepted signed rule registry. Its dispatcher
path requires `evaluationFiles[n].projectEvidence` with this bounded
in-memory shape:

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

This is an **attestation contract**, not a path or name heuristic: the
bounded read-only intake/provider must enumerate *all* projects compiling
the exact changed file at the pinned source commit, verify the changed-file
and project blobs at that commit, evaluate supported project graph
constructions, and establish each owner's effective `IsTestProject`.
The provider must prove completeness of the owning-project set before setting
`complete: true`. A bare project name, directory prefix, `Tests.cs` name,
MSTest attribute, SDK reference, or unevaluated `.csproj` text does not
establish this identity. The dispatcher checks the attestation's shape and
source/repository/path/blob binding, as well as a fresh Changes proof and
generation receipt, but does not execute MSBuild from this envelope.

Absent, incomplete, stale, contradictory, malformed, or duplicate membership
is `test-project-identity-unknown`, not a clean result. A source file in
multiple projects is test-scoped only if **all** confirmed owners are test
projects; mixed test/product ownership is unknown. Confirmed product-only
membership is skipped for these `@2` rules. An actionable construct identity
also includes a digest of its project attestation, without persisting raw
project graph or source content.

The optional `projectEvidence` intake configuration (`schemaVersion: 1`,
`enabled: true`, `maxTreeEntries`, `maxProjects`) now requests this proof
for selected active, non-draft master-target PR heads. It is disabled in
the sample. A single bearer obtained for the pinned ADO identity resource
must pass a direct connection-data GET against the configured account
before any direct octet-stream item GET. Changed source and project files
are requested by **commit and path**, and their raw bytes must hash to the
expected Git blob IDs. The source commit's root tree ID is read by GET;
every directory is fetched without recursion, its Git tree bytes
reconstructed and SHA-1-checked, and the walk stops at the configured
entry, read, time, or byte limit. An incomplete/truncated tree response
cannot silently omit an owner because its hash would differ. No fallback
to ADO's rendered item text, an unverified external file, or a project-name
guess is permitted. A raw-byte read or identity mismatch is unknown.

The safe evaluator accepts pinned explicit `Compile` includes, excludes,
removes, links and globs, plus resolvable simple imports and conditions. A
narrow, uncustomized `Microsoft.NET.Sdk` profile covers the standard default
C# glob (including nested fixture/helper classes). It refuses unproven
SDK defaults, customized or generated item graphs, ambiguous properties,
outside-repository imports, and unsupported conditional constructions.
An inventory with a non-C# MSBuild project or an unaccounted `.props`,
`.targets`, or `.projitems` file is unknown rather than treating the
enumerated `.csproj` owners as complete. A non-SDK project may explicitly
import a pinned file that the restricted evaluator can fully parse. It
never runs untrusted MSBuild targets or property functions.

Only a `source-bound-project-scope-summary-v1` receipt, not paths, project
XML, source, or the owner graph, is saved in the immutable intake generation.
The receipt binds its generation, declaration digest, repository, source
commit, root tree and per-changed-C# path/blob/attestation digests. Missing,
ambiguous, unsupported, over-budget, or mixed-scope files cannot be
promoted to an evaluated `@2` observation; enabled `@1` rules and their
existing change path remain unchanged. The read-only dispatcher checks
the receipt against a fresh Changes GET and puts its digest in `@2`
declarations/observations; the dashboard independently checks the current
generation binding before counting an `@2` evaluation.

The `@2` capabilities remain outside the accepted signed rule registry.
A separate later layer must add independently approved immutable `@2`
policy/capability bindings before activation. This layer does not sign
private policy, create an evaluation manifest, enable a task or writer,
post a comment, or assert any live canary result.
