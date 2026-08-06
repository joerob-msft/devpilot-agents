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
read-only tools: pull-request and repository-file reads. Its nonce-bound
`CONVENTION_REVIEW_RESULT_V1` marker permits `suggestion` and `important`
convention candidates only. Wrapper validation rechecks source quotes, pack
membership, fact IDs, severity rules, sibling evidence, and current changed-file
anchors. Invalid anchors are withheld rather than relocated.

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
in the runtime data names one required row per transported source, plus the
`cf<n>` anchor ids for the changed files the wrapper delivered. Each row states:

- the pack, source id and source hash it is about, and an exact quote from it;
- a `status` of `violation`, `compliant`, `notApplicable` or `unknown`;
- the changed anchors it checked, as `cf<n>:<line>`;
- the code evidence, and the sibling evidence or why none was needed;
- the id of the candidate it produced, or a note saying why none was emitted.

`unknown` is a first-class answer. Source that was not delivered, sibling
practice that could not be established and ambiguous rule text are all honest
`unknown`s, and each says which in its note.

The wrapper then reconciles the rows against the set it transported, which it
computed itself:

- a source with no row is reported **missing**; a source with two rows is
  reported **duplicated**; a row naming a source that was never transported is
  reported **unknown** and is not counted toward coverage;
- a row whose source hash, quote or anchor does not match what was actually
  transported is degraded to `unknown` with the reason recorded;
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

The anchor ids are the only deterministic anchors the wrapper supplies: the
changed files, ordinally sorted, from the change set it delivered. Pattern
hints for particular rule shapes are deliberately **not** generated. They would
steer the model toward exactly the categories the hint generator enumerates, so
measured recall would become a property of that generator rather than of the
specialist - which is the opposite of calibration.
