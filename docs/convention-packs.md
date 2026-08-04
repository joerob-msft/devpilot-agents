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

The wrapper reads the PR change set twice around exact source-commit and
target-branch checks. Both normalized change-set digests must agree. A response at
the transport's 1000-entry ceiling is treated as potentially truncated and fails
closed.

Paths are repository-relative. ADO `/src/a.cs`, Windows `\src\a.cs`, and
`src/a.cs` normalize to `src/a.cs`. Drive, UNC, control, empty, absolute config,
and `.`/`..` forms are rejected. Comparison is ordinal case-insensitive without
Unicode normalization. Configured globs are ASCII and support:

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
context cap. Startup rejects a cap that cannot fit declared source maxima plus
minimum required provenance. Runtime uses actual bytes and rejects a one-byte
overflow. The total convention-context cap is code-defined at 131072 bytes and
cannot be widened by config. Per-pack and total accounting conservatively charge
a reused source to each selected pack.

No rule is truncated. A cap or deterministic provenance failure writes a
structured failed plan, increments that PR's bounded failure count, prevents that
PR's model launch, and leaves other PRs in the cycle eligible. Transport,
credential, timeout, or concurrent source/target movement also fails that PR
closed, but is recorded as an environment fault and does not push the PR toward
starvation.

Ready plans contain no decoded convention text. They contain exact source
coordinates, hashes, byte counts, selection evidence, script/config hashes, and
the change-set digest needed for the later specialist layer to resolve and verify
the same bytes. Plans are saved under the reviewer state directory's
`convention-plans` folder and are not posted or voted on.
