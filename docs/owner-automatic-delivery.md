# Owner automatic delivery

`AutomaticOwnerV2Comments.ps1` is the production create-only delivery layer
above the completed Owner v2 observation and PR discussion reconciliation. It
does not give the model a tool or authorization. The scheduler runs the
read-only Owner observation first, and only the trusted wrapper can enter this
delivery phase.

```text
Owner prepare/run (model tools = [])
        |
completed live Owner observation
        |
discussion classification = wouldCreate
        |
signed deployment policy + live wrapper revalidation
        |
at most five anchored CreateThread calls
        |
readback + signed intent/outcome/event artifacts
```

This repository change does not register or modify a scheduler, deploy a key,
enable a policy, or post a live comment.

Stale pull request status authority is a separate lifecycle lane described in
[`stale-pr-lifecycle.md`](stale-pr-lifecycle.md). It does not reuse any Owner,
Named, or contextual comment key, policy, quota, intent, outcome, or event.

## Exact authority boundary

Automatic authority permits only an Azure DevOps `CreateThread` operation for
an exact completed `bpm-test-ownership@1` finding that:

- is a `violation` on one changed method-level MSTest construct;
- still has the exact immutable source head, method binding, and current
  changed-line anchor, so the completed missing-Owner finding still describes
  the live source;
- has the configured rule, capability, reviewer identity, toolkit head/tree,
  formatter, writer, provider, and scheduler digests;
- has a complete current discussion snapshot whose live classification is
  exactly `wouldCreate`; and
- remains on the same active non-draft PR source head, target commit, target
  ref, repository, project, and current iteration.

The authority explicitly excludes class findings, advisory, `notEligible`,
`unknown`, uncovered evidence, relation capability, `wouldUpdate`, thread
status changes, resolve operations, votes, PR status, summaries,
notifications, and every other provider write. An existing exact comment is
`noOp`. A copied foreign marker, duplicate marker, stale body, changed source,
changed anchor, pagination failure, identity mismatch, or any other drift is a
refusal. The model runner remains `effectiveTools: []` and cannot see, request,
or authorize this phase.

When a deterministic reviewer upgrade changes its current marker or formatter,
an earlier contextual comment can remain `noOp` only through authenticated
delivery history, including when only its body changes and its marker stays
the same. The reader verifies the lane key on the signed create event,
intent, and outcome, links their run/event/state identities, requires the same
immutable PR source and target, rule content hash, construct identity, path,
line, and symbol, and then requires the exact live reviewer-owned comment,
thread ID, comment ID, body hash, active status, current context, and anchor.
The rule commit and implementation may advance while the authoritative rule
hash and construct remain identical. Copied, edited, deleted, moved, duplicate,
foreign-identity, stale-head, or changed-rule evidence remains unknown and
cannot authorize a create, update, or rewrite.

## Finding presentation

Contextual, named-assertion, and Owner findings use actionable bold titles,
readable rule names, a concise explanation, and a **Changed-line occurrences**
list. With a configured subject provider, every displayed occurrence has its
own source-commit-pinned link;
named-assertion groups still show at most the first twelve calls and explicitly
report truncation. This changes neither the method grouping nor the full
typed call list used by preflight.

Source links are built from the existing subject provider's HTTPS organization
and the contract's project/repository IDs. A mismatching provider scope is
rejected; rule-reference URLs cannot change finding anchors or write scope.
Both current-PR bridges and approved-evidence reconstruction use that same
presentation context, including completed-observation discussion refresh.
Custom acquisition providers can pass the same context through
`New-OwnerAzureDevOpsReadOnlyProviderAdapter -CommentPresentation`, with
`subjectProvider`, `ruleReferences`, and `ruleRepository` members.
An existing source-artifact slot records the render-mode discriminator, not
new authority. Reconstruction applies linked context only when the observation
declares that mode; custom Owner providers that omit it retain their plain
locations and matching body digests. Unknown or duplicate mode artifacts are
rejected. The existing exact body digest binds the actual rendered citations.
The dot-sourced approved writer imports its canonical harness dependency
directly; provider preflight does not rely on a prior wrapper or test-suite
import to make canonical digest helpers available.

The integrated contextual policy has **27 rules**. The additive
`english-identifier-naming` rule is distinct from `named-call-arguments`.
The preceding 26 definitions, including the narrowly bound static string
equality exception, are unchanged. The sample remains disabled; source integration
does not install a toolkit, authorize a policy, or enable production delivery.

Shared acquisition remains hosted by the Named-only roster and its existing
`includePullRequestTemplateAuthority` flag. The producer retains already-read
comparison bodies within the same 16,777,216-byte source-plus-comparison budget,
including resumed progress. The contextual consumer validates that comparison
against the immutable heads, paths, lengths, and digests before deriving missing
header authority. It never requires Named to host contextual rule definitions or
fetch unchanged contextual reference files. A withheld newness check remains
UNKNOWN while independently proven findings still receive discussion
reconciliation; an incomplete evaluation is not relabeled completed.

Historical compatibility retains the five older explicit signed unchanged-ID maps:
18 IDs for the original 18-rule bundle, 20 IDs for the pre-nuance 21-rule
bundle, 20 IDs for the post-nuance 21-rule bundle, 21 IDs for the template
22-rule bundle, and 25 IDs for the preceding 26-rule bundle
(`275a62e22d849913ea0da332fdb07dfb6ebed155231236c7704b94f4fb031938`,
10,287 canonical CRLF bytes). `named-call-arguments` is excluded from those five
older generations: its changed semantics are not additive unchanged history.
The four most recently added IDs remain excluded from the first four maps.
The original 18-rule map includes `test-class-code-coverage`;
do not replace these maps with a current-roster count or an inferred blanket
compatibility grant.

An additional exact predecessor map for bundle
`9221ce2c9cb4777bb0cbfc0ed11dea9e0e68328ce98137a026c4b68b4c80c756`
(11,517 canonical CRLF bytes) permits its 26 unchanged IDs, including the
already-updated named-call semantics. The new naming rule belongs in none of
these six historical maps. The five older maps above retain exactly
18/20/20/21/25 IDs; adding this map does not retroactively authorize the changed
named-call rule in those older generations.

File-header locations and related source occurrences use distinct labels;
neither implies an unchanged line was changed. PR description findings remain
top-level. All four new rules have independently rooted, commit-pinned sample
citations to their verified CodingStyle headings.

The optional toolkit-config `commentRuleReferences` map supplies verified,
human-facing citations without changing source acceptance or rule semantics.
Keys are contextual rule IDs, `named-areequal`, or `owner`. Each entry has
`label` (`EngHub rules` or `Rule references`) and one to eight `links`, each
with `name` and an HTTPS `url` pinned by `version=GC<commit>`, `path`, and
`line`. Configure the independent `commentRuleRepository` binding alongside
the map with exactly `organization`, `projectName`, and `repositoryName`.
The examples pin the verified EngHub repository; a URL never supplies its own
trusted root. The configured Azure DevOps cloud organization can use
`https://dev.azure.com/<org>` or an explicitly configured
`https://<org>.visualstudio.com[/<collection>]` alias. Links must use that
exact organization/project/repository prefix; unconfigured aliases are not
inferred to be equivalent.

Both bridges and approved reconstruction validate **all** configured
references before evaluating or selecting findings, including unused rules.
Unknown rule IDs, extra/missing object keys, empty/scalar link lists, external
hosts, user information, URI fragments, duplicate/unexpected query keys,
unpinned versions, nonpositive lines, and noncanonical rooted paths are
rejected. Only one each of `version`, `path`, and `line` is allowed; paths
cannot contain traversal, backslashes, empty segments, or double-encoded
escapes. Direct standalone formatting also validates the complete map: on an
invalid citation it emits a warning and the plain readable rule name, never
a partial or untrusted clickable citation group.

Verify that the named section actually exists at that exact location;
do not derive line numbers from a different document revision. The sample
configs include verified named-argument section references. Rules without
configured citations display their readable names, never fabricated links.
These citations are presentation metadata, not new evaluation authority.

Exact rule hashes and bindings remain in observations and signed delivery
records rather than a rule-bundle hash paragraph. PR-template findings stay
PR-wide: their template link uses the effective default-branch commit, with
no invented code occurrence. A collapsed template-provenance block retains
the existing exact template-content evidence needed for missing-section
subset reconciliation across default-branch advances.

Existing canonical Owner and named-assertion bodies remain recognized as
`noOp` under their unchanged identity, marker, anchor, and current-context
checks. Contextual historical bodies require the existing signed history
proof, whether their marker changed or not. A presentation upgrade never
rewrites an old comment; conflicting or unverifiable contextual/Named markers
remain `unknown`. Owner's explicitly approved stale-body update path otherwise
retains its existing behavior.
Authenticated contextual history uses the same finding-range boundary as
normal reconciliation. Ambiguous, cross-rule, or unproven human comments
elsewhere in a duplicate-constant finding's bound span prevent a history
no-op; proven coverage and unrelated comments outside the span retain their
existing behavior. Copies of either the current or authenticated prior marker
in another comment are conflicts, and the authenticated body itself must
contain exactly one recognized automation marker.

## Contextual rule behavior

The contextual bundle also enforces EngHub's general named-call convention as
one rule group. A changed invocation, object construction, or `this`/`base`
initializer requires every supplied argument to be named when selected formal
parameters repeat a semantic type or each argument starts on its own line.
When only the constant trigger applies, only supplied proven compile-time
constant arguments need names. The implementation
uses a unique same-file/snapshot signature and
never guesses parameter names. It excludes `Assert.AreEqual`, which remains
owned by the separate MSTest rule. Ambiguous overloads, dynamic calls, expanded
`params`, unsupported expression-tree syntax, or unknown language-version
evidence remain unknown and cannot reach delivery.

Argument names are optional for semantically bound static
`System.String.Equals(string, string)` and
`System.String.Equals(string, string, System.StringComparison)`, including
`comparisonType`. This exception overrides all three triggers. Roslyn resolves
the selected method against the existing bounded C# snapshot and framework
reference; the declaring type and exact parameter types must match framework
symbols. Qualified/global names and type aliases are supported when binding
proves them, not because their text resembles `String.Equals`. Dynamic,
unresolved, malformed, or relevant conditional binding remains UNKNOWN.
Instance, object, custom equality, assertions, ordering comparisons, and other
same-type/constant calls are not exempt. Only the two string operands are
interchangeable; comparison mode is not another string operand.

The source policy and disabled sample explicitly cite user-directed proposed
[EngHub PR 17634453](https://msazure.visualstudio.com/DefaultCollection/One/_git/AzureUX-BPM-EngHub/pullrequest/17634453),
commit `6cc598bff64c224e60a7789de19f5d5d82d3764d`, CodingStyle.md
headings 547/592/662 and shared exception section 621-660. That PR is not
merged/default-branch authority. Source integration does not authorize an
installed mapping or policy to consume it: a later operator must explicitly
accept that exact proposed commit, or repin to verified merged documentation.
The existing exact repository/commit/path/line citation validator is unchanged;
there is no fallback to `master` or decoded API text as raw Git-byte proof.

The contextual bundle's `pr-template-compliance` rule is PR metadata, not
changed-line analysis. It selects one effective
`/.azuredevops/pull_request_template.md` or `.txt` from the repository's
current default-branch commit and requires meaningful authored content under
Problem, Solution, and Validation. Bold-colon and equivalent ATX headings are
accepted; headings in fenced code or quoted examples are ignored. Copied empty
scaffolds do not satisfy the rule. Optional release notes, the optional full
test pass, conditional bundle/settings checks, and unchecked checklist items
are not required.

Its finding uses an explicit `pull-request` / `description` binding and is
delivered as a top-level PR thread with no file, line, symbol, or code anchor.
Evaluation and every live create preflight bind the exact description digest
and effective template path, ref, default-branch commit, blob, and content
digest. Description edits or template drift refuse the stale create. A
separate stable issue identity covers the same missing-section set and
identical effective template content, so an existing reviewer marker or
current human request remains a no-op across invalid description revisions or
a default-branch advance that preserves the same template blob/content.
Changed missing requirements require new proof; they are never blindly
promoted from history. Contextual automatic delivery remains create-only,
model-free, and capped at two creates per run and five creates per PR.

The contextual `block-body-indentation` rule implements the demonstrated
EngHub four-space block-body requirement. Roslyn identifies direct statement
starts inside C# blocks. A finding anchors to an exactly changed
statement-start line, or to a changed `try` opening brace when the `try`
header also changed and its existing body is now under/over-indented.
The demonstrated PR adds `try`/`{` at lines 105-106 while moving unchanged
`if` text to line 107: the correct changed anchor is 106, not 107.
A standalone opening brace with a spaces-only prefix
establishes the baseline, and the statement must start exactly four spaces
further right. Tabs in a changed statement prefix, under-indentation, and
extra increments violate this supported check. Old unmodified indentation is
not cleanup scope.

This is not a general C# formatter: continuation arguments, fluent chains,
initializer members, and unbraced embedded bodies are not checked. Literal
contents, interpolation contents, comments, blank lines, and generated/deleted
files cannot become statement anchors. Conditional compilation without proven
configuration, incomplete syntax, labels, inline block layouts, and
tab-indented baseline braces are explicitly unknown rather than guessed
compliant. No project language-version or semantic binding is needed to
measure a syntax-proven block's whitespace.

A current review on the proven opening brace that explicitly requests body
indentation counts as `humanCovered`, even though the finding remains
anchored to changed code and binds the measured statement line. Unrelated brace reviews are withheld as
unknown. Existing exact reviewer markers retain the usual no-op/dedupe
behavior. The rule uses the existing create-only, model-free delivery path;
it does not enable or alter live runtime configuration.
A markerless comment owned by the configured automation actor is not
relabeled as human coverage: without authentic prior proof or an exact
current marker, it is unknown and cannot authorize a duplicate create.

For authorization, preserve the five older exact historical maps described above.
`block-body-indentation` is accepted only in the immediately preceding
26-rule map, never in the first four. These proofs are explicit and signed
per rule; there is no blanket old-bundle compatibility.

The additive `generic-exception-naming` rule requires `ex` only for a catch
variable bound by Roslyn to the framework's `System.Exception`. It resolves
qualified types, aliases, and snapshot-local shadowing; it does not infer a
specialized exception naming convention or flag nested test helpers. A finding
is anchored to an actual changed token in the catch declaration, not a changed
filter/body beneath an old declaration, and asks the author to update all uses.
The identifier line is preferred when changed; delimiter-only edits do not
make an unchanged type/identifier eligible. Generated paths, auto-generated
banners, and generated-attributed ancestors exclude catch findings. Generated
snapshot files retain their compiled types, imports, and declaration structure
for binding; only generated executable block interiors are masked with original
coordinates preserved. Noncompiled `obj` and reference-only paths are ignored.
Conditional method bodies or unrelated snapshot directives
do not withhold resolved catches. Changed inactive catches and conditional
imports/type declarations that can affect binding remain unknown. Inactive catch
relevance is checked at its catch keyword line, not an unrelated edited line
elsewhere in the same disabled block.
No source edits are performed. Missing/ambiguous type binding, conditional
binding, or malformed syntax is unknown, not compliant or a violation.
Resolution uses the bounded current-source snapshot and the framework reference,
not a full repository build; unrelated compilation diagnostics do not veto a
resolved catch type. A current human naming request must mention the same
variable and request `ex` at the exact current anchor to suppress a duplicate.
Unrelated or stale discussion does not establish naming coverage.

Preserve the five older exact historical maps and do not promote a rule into a
bundle that did not accept it. `generic-exception-naming` belongs only in the
preceding 26-rule map; `pr-template-compliance` belongs in the 22- and 26-rule
maps. The changed named-call rule belongs in none of those five older maps;
only the additional `9221ce2c...` predecessor preserves its current semantics.
The existing schema-v2 signed compatibility format, create-only authority,
zero model starts, two total contextual creates per run, five per PR, and four
heads per scheduled run are unchanged. Adding the rule does not deploy it,
rewrite installed configuration, authorize a policy, or change scheduled tasks.

The additive `english-identifier-naming` rule implements a deliberately bounded
part of **Use English terms** in canonical EngHub CodingStyle.md, commit
`ff0692776598b8eb07993e8c45e0be03b7e32fa3`, heading 1734 and clause 1737.
That clause requires complete, unabbreviated English terms and rejects uncommon
abbreviations/acronyms. The user-supplied AzureUX-BPM PR 14099142, thread
267600437, demonstrates `p` -> `property` in `XmlComposer.cs:257` at source
`71aa9b0e09f2747f75452eb665abd16879352df5`:
`holder.Properties().FirstOrDefault(p => p.Name.StartsWith(...))`.

The supported finding requires an actually changed single-ASCII-letter
lambda-parameter identifier (for example `p`, `x`, or `q`) whose Roslyn symbol
type equals the referenced `Newtonsoft.Json.Linq.JProperty`. It asks for a
descriptive English term such as `property` and updates to that
lambda's uses. The existing PowerShell 7 runtime supplies Newtonsoft and framework
metadata; no package, dictionary, model, or repository-wide naming heuristic is
added. Qualified types, aliases, inferred parameters, and independent nested
scopes are resolved semantically, not by the spelling `JProperty` or `Properties`.
Source-defined lookalikes and proven foreign types are outside the supported role,
not naming violations. Unresolved/dynamic targets, incomplete snapshot binding,
and relevant conditional compilation are UNKNOWN. An old parameter does not
become eligible because its body, enclosing call, or unrelated line changed.
Generated paths, banners, and attributed ancestors reuse existing exclusions.
Inferred roles are conservatively withheld if any conditional-compilation range
remains in the bounded binding snapshot: unselected overload or local declarations
can change lambda target typing without changing the lambda itself. Explicitly
typed property roles are not withheld by unrelated conditional method bodies.

This is not general English-name validation: other lambda names, method/local/
field/type declarations, domain terms, common acronyms, loop counters, and discards
are not classified by this supported check. Descriptive names such as `property`,
`currentProperty`, and `candidate` are retained. A no-supported-candidate result does
not certify their names as English. A current distinct-human request must mention
the same variable and request `property` or `currentProperty` at the same current
anchor to suppress a duplicate.
Unrelated, negated, copied-marker, or markerless reviewer-owned discussion cannot
establish human coverage; exact current reviewer marker/body readback is a no-op.
No live policy, installed runtime, provider write, or timer is enabled by this
source change. The parent operator still owns acceptance and production delivery.

The additive `file-copyright-header` rule checks C# files in the current
changed-file inventory, including modified existing test files. It implements
the canonical EngHub CodingStyle.md **Copyright header** section at line 929
(commit `7cbaf3ef94e3bec3af10875b7c6a2690d111416b`): two dash-separator
comments around `// Copyright (c) Microsoft Corporation.  All rights reserved.`
before any code. BOM, LF/CRLF, and horizontal whitespace are supported. The
same notice may include a four-digit year or hyphen-separated year range;
historical years are accepted without annual rollover.
The rule does not require a year, inspect unchanged files, or
claim other languages are implemented. Generated, vendored, deleted, and
context-only files are excluded; unavailable source or comparison authority
is unknown, not compliance.

The finding uses a typed `file-header` anchor at the physical start of the
changed file, not a changed-line claim. Existing canonical path/span binding
is retained; separate header evidence binds source and comparison commits,
content digests, change type, and original rename path. The actual intake and
every provider create preflight derive that evidence from source and target.
Missing headers on new files or after header removal are introduced; a missing
header on both sides is explicitly **pre-existing and nonblocking**, not a
regression. Both kinds are nonblocking comments only. A current distinct human
copyright request anywhere in the same file suppresses a duplicate; a
markerless automation/reviewer-owned request or unproven prior context remains
unknown. Exact current reviewer-owned marker/body readback is a no-op.

Preserve the five older exact historical maps described above. `file-copyright-header`
belongs only in the preceding 26-rule map, never the older four;
`pr-template-compliance` is absent from the 18/20/21-rule bundles.
Existing create ceilings, run/PR history, idempotency, Owner behavior,
and model-free/create-only authority are unchanged. This source change does
not enable a live policy or perform any provider writes.

The separate `reused-string-literals` rule implements the canonical
**Declare constants for re-used strings** section. It compares Roslyn-decoded
string literal expressions, not raw text counts or constant declarations.
Only a changed literal use can own a finding; unchanged repetitions by
themselves do not trigger cleanup. Existing constant member references,
comments, attributes, generated sources, localized resource member references,
and repetitions confined to a proved test project are not candidates.
Escaped, verbatim, and supported raw string spellings share their decoded
value identity; comparisons are ordinal and case-sensitive.

New reuse requires an increased count of eligible decoded literal uses relative
to the exact comparison revision, not merely a line marked changed. A moved or
rewritten six-use value that remains six uses is not new reuse. This is bounded
occurrence evidence, not a general semantic diff: equal/decreased counts are
not reported. Every participating C# baseline must be available and parseable.
Missing, malformed, conditional, wrong-path, wrong-head, or tampered comparison
evidence is unknown and cannot be substituted with an empty target.

The shared producer retains the already-read comparison text with source and
target commits, current/old path, both content digests, absence state for added
files, and byte length. It adds no read or roster flag. Both source and target
text count against the existing file/package/progress byte ceilings; persisted
progress retains the baseline under the existing code-head binding. The
hash-pinned shared generation is checked at the consumer, and its provider and
adapter revalidate the comparison binding before the analyzer can use it.
Old progress lacking this evidence remains usable by other rules, but cannot
prove this rule's newness. Source-only cited peers without comparison evidence
likewise do not prove a clean or newly reused result.

The rule consumes the existing bounded, accumulated full-PR snapshot and each
file's source-pinned `projectContext`. Cross-file and context-only peers remain
visible through the capability adapter. One deterministic changed-use anchor
owns each decoded value independently, regardless of acquisition ordering. A
class-local value is never merged with a cross-project value to select
placement, ranges, or advice. A uniquely proved accessible constant is
recommended for reuse rather than another declaration. The finding
retains its exact changed start/end range and related literal uses. A class-local
cluster calls for `private const string` atop that class; cross-class reuse calls
for `public const string` in a common project Constants class; cross-project reuse
calls for the lowest common project dependency without inventing its identity
or dependency direction. Unproved project/syntax/conditional evidence is
`unknown`, not a clean pass or a deliverable finding. The existing
`duplicate-constant-declarations` rule keeps its separate semantics.

A current human request covering every literal value at a related use prevents
a duplicate comment. When a provider exposes only a range's first line, an
explicit citation to a related use at the exact source commit can establish the
same coverage. Partial, stale, unrelated, or ambiguous coverage cannot authorize
delivery. Quotas, signed history, Owner behavior, model-free evaluation, and
create-only delivery are unchanged.
An existing markerless comment from the configured reviewer is not human
coverage: without authenticated prior delivery proof, it stays unknown and
cannot authorize another create.

When authorizing this additive bundle, retain all six exact prior bindings
with 18/20/20/21/25/26 unchanged IDs. Use
`-PreviousRule*`, `-AdditionalPreviousRule*`, `-ThirdPreviousRule*`, and
`-FourthPreviousRule*` for the older four maps and `-FifthPreviousRule*` /
`-FifthUnchangedRuleId` for the older `275a62e2...` 26-rule map. Use
`-SixthPreviousRule*` / `-SixthUnchangedRuleId` for the exact `9221ce2c...`
26-rule predecessor. The existing schema-v2 maximum of eight maps is unchanged;
the added CLI slot is needed to retain all five old maps alongside this new
predecessor, not to create new authority. Never include `english-identifier-naming`
in any prior map, `named-call-arguments` in the first five, or
`pr-template-compliance` in the older 18/20/21-rule sets.
The fifth map preserves the other 25 IDs, including `reused-string-literals`;
the sixth preserves all 26 predecessor definitions. An old named-call comment without current
proof remains UNKNOWN/no-duplicate, not authenticated unchanged history.
This source change does not enable or deploy the correction.

The manual signed-selection writer remains available for human-controlled
creates or explicitly approved updates. Automatic service authorization uses a
different local key, policy kind, intent kind, outcome kind, directories, and
CLI. A human approval artifact cannot be substituted for a service policy.

## Fail-closed configuration

`autoCreateOwnerComments` is absent or `false` by default. A true boolean is
invalid because it has no immutable policy binding. Enabled configuration is
external deployment data and has exactly this shape:

```json
{
  "autoCreateOwnerComments": {
    "enabled": true,
    "policyPath": "C:\\private\\owner-v2-delivery\\policies\\owner-v2-production.json",
    "policySha256": "<64 lowercase hex>"
  }
}
```

The policy path must be absolute, inside the private delivery root, owner-only,
and match the configured file digest. The HMAC-signed policy binds:

- exact project/repository, rule, capability, and reviewer identity;
- toolkit head/tree and formatter, manifest, approved-writer, provider,
  automatic-writer, and scheduler file digests;
- create-only/wouldCreate/method-violation authority;
- maximum creates per invocation (hard repository ceiling 5); and
- maximum creates per PR (hard repository ceiling 50).

Each signed run intent additionally binds the exact state identity, durable
result digest, observation file digest, source/target/ref, current iteration,
discussion snapshot, rule, capability, reviewer, implementation policy, and
ordered selections.

Initialize a private service key and authorize a deployment policy while
delivery is still disabled:

```powershell
$delivery = 'C:\private\owner-v2-delivery'
$tool = '.\tools\Invoke-AutomaticOwnerV2Delivery.ps1'

& $tool initialize-key -DeliveryRoot $delivery

& $tool authorize-policy `
    -DeliveryRoot $delivery `
    -StateRoot C:\private\owner-v2-state `
    -Identity <completed-owner-state-identity> `
    -ToolkitConfigPath C:\private\owner-v2-config.json `
    -PolicyId owner-v2-production `
    -MaxCreatesPerRun 5 `
    -MaxCreatesPerPullRequest 25
```

Record the returned policy path and SHA-256 in the external config, then use
the scheduler wrapper:

```powershell
.\tools\Invoke-OwnerV2ScheduledDelivery.ps1 `
    -StateRoot C:\private\owner-v2-state `
    -ManifestPath C:\private\owner-v2-cohort.json `
    -ToolkitConfigPath C:\private\owner-v2-config.json `
    -DeliveryRoot C:\private\owner-v2-delivery `
    -EnableLiveModel `
    -LiveModel <qualified-model> `
    -LiveCredentialEnvironmentName COPILOT_GITHUB_TOKEN
```

There is no approval UI and no ask-user step. Configuration and signed policy
are the wrapper-owned deployment authorization.

## Delivery behavior

The wrapper holds an exclusive delivery lock and sorts Owner state/finding
identities deterministically. One scheduled invocation creates at most five
comments across the cohort. Every individual create receives a fresh read of
the PR, current iteration, changed source and anchor, reviewer identity, and
complete discussions. Read-only preflights have bounded exponential backoff,
and confirmed creates are paced before the next selection. The create is issued
once and is never blindly retried.

After the create, the wrapper reads the authoritative discussions and requires
one exact reviewer-owned marker/body. If a provider error occurred after the
write but the comment is visible, the outcome is
`created-confirmed-after-error`. If readback is unavailable or does not confirm
the comment, the marker is durably blocked as `ambiguous-post-write`; the
possible write is conservatively charged against both run and PR ceilings, its
event reports `providerWriteState: unknown`, and later automatic runs refuse
the entire PR until incident handling resolves the uncertainty.

An interrupted signed intent is reconciled before new work. One exact live
comment becomes `recovered-confirmed` with zero recovery writes. An absent or
ambiguous comment becomes `operator-review-required`; recovery never guesses
that a create is safe.

With nine eligible findings, isolated provider proof is:

1. first invocation: five creates, four remain;
2. next scheduled read/reconcile plus delivery: four creates;
3. next scheduled read/reconcile: all nine are `noOp`, zero writes; and
4. later hourly invocations: zero writes while the PR state remains unchanged.

## Durable delivery event feed

The dashboard-facing feed is the immutable signed files under:

```text
<delivery-root>\events\<event-id>.json
```

Consumers enumerate files, verify each HMAC envelope with the private
deployment key, parse `manifestJson`, and sort by `(occurredUtc, eventId)`.
They must not infer success from intents or process exit alone.

The stable payload is `schemaVersion: 1`,
`kind: owner-v2-delivery-event`:

```json
{
  "schemaVersion": 1,
  "kind": "owner-v2-delivery-event",
  "eventId": "<opaque id>",
  "runId": "<opaque id>",
  "occurredUtc": "yyyyMMddTHHmmssZ",
  "runHealth": "healthy|partial|refused",
  "subject": {
    "projectId": "<opaque id>",
    "repositoryId": "<opaque id>",
    "pullRequestId": 42,
    "sourceCommit": "<40 hex>",
    "targetCommit": "<40 hex>",
    "targetRef": "refs/heads/main"
  },
  "finding": {
    "stateIdentity": "<64 hex>",
    "findingId": "owner-v2:<64 hex>",
    "marker": "<64 hex>",
    "scope": "changed-line",
    "path": "tests/WidgetTests.cs",
    "line": 12,
    "symbol": "CreatesWidget"
  },
  "action": "create|none",
  "outcome": "created|created-confirmed-after-error|recovered-confirmed|noOp|refused|ambiguous-post-write",
  "threadId": 100,
  "commentId": 1100,
  "url": "https://dev.azure.com/...&discussionId=100",
  "modelWriteCount": 0,
  "providerWriteCount": 1,
  "providerWriteState": "none|confirmed|unknown",
  "diagnostic": {
    "code": "<stable code>",
    "message": "<bounded sanitized message>"
  }
}
```

For the PR-template rule, `finding.scope` is `pull-request`; the event carries
`subject: "description"`, `metadataSha256`, and `issueIdentity` instead of
`path`, `line`, and `symbol`.

No comment body, UPN, credential, token, raw provider response, or model packet
is in the event. IDs, path/line/symbol, hashes, URL, health, outcome, bounded
diagnostic, and write counts are sufficient for dashboard status and drill-in.

Scheduler result exit codes are truthful: `0` for healthy or disabled, `2` for
partial/cap-bounded work, `3` for refused delivery, and `1` for an unhandled
failure. A partial result may include confirmed creates; operators must read
the signed events and outcome.

## Disable, rollback, and incident response

The immediate disable switch is:

```json
{ "autoCreateOwnerComments": false }
```

Stop the scheduled wrapper or set that value before changing policy, key, or
provider configuration. Disabling delivery does not alter observations,
comments, manual approvals, or relation preview. Preserve keys, policies,
intents, outcomes, and events for audit. Never delete a provider comment as an
automatic rollback action.

For an ambiguous write, identity drift, duplicate marker, corrupted audit, or
unexpected provider count:

1. disable automatic delivery and preserve the private root;
2. inspect the live PR and signed intent/outcome/events;
3. reconcile the exact marker/body/thread manually;
4. correct or replace the external policy/configuration;
5. prove a private/fake canary with zero external writes; and
6. re-enable only after the block has a documented resolution.

## Key rotation

Keys are never stored in source, logs, model input, config, events, or policy
payloads. The delivery root and key must pass the harness private ACL checks.
To rotate:

1. disable and stop the scheduled delivery phase;
2. retain the old root read-only for historical verification;
3. initialize a new private delivery root/key;
4. authorize a new policy under that key;
5. atomically update the external path/digest binding;
6. run private/fake create, 5+4, no-op, recovery, and refusal canaries; and
7. resume the scheduler.

Do not overwrite a key in place: historical signed artifacts require the key
that created them.
