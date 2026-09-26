# Redundant method-level coverage exclusion

`bpm-redundant-method-coverage@1` is a separate, user-approved convention
motivated by a human review of an Azure DevOps pull request. It is **not**
derived from the EngHub Owner section. Its versioned text is
[`redundant-method-coverage.v1.txt`](../src/DevPilot.OwnerCapability/Policy/redundant-method-coverage.v1.txt),
SHA-256 `3cecab1d5483531a1e899aa8ca71d999b96f1135a302193b1a34c72938b8d6df`,
220 bytes. Git preserves those exact policy bytes.

In a C# MSTest class with changed method attributes, method-level
`[ExcludeFromCodeCoverage]` attributes are redundant when the containing
`[TestClass]` already has a
class-level `System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute`.
There is **one class-level finding and at most one comment per class**, even
when many changed methods have redundant exclusions. The suggested fix removes
only the affected method-level exclusions, preserving `[TestMethod]`, other
method attributes, and the class exclusion. A class-only exclusion is not a
finding. The deterministic, model-free capability consumes immutable
source/target-bound files and complete changed spans through the existing
bounded read-only preview facade. It ties the class-level finding to the
current source commit, exact first changed method-attribute anchor, containing
class symbol, rule, and capability. The finding records the total affected
attribute count, up to 12 sanitized distinct method names, whether the list
is truncated, and at most 256 exact changed attribute opening lines. If one
affected method cannot be established confidently, the whole class is unknown,
not a partial actionable finding. Unknown syntax, unresolved
attribute names, partial classes, preprocessor directives affecting the
construct or its imports, malformed C#, duplicate exclusions, or mixed
attribute lists produce unknown outcomes rather than an actionable finding.
An isolated conditional `using` alias unrelated to the rule's namespaces or
attribute names can be discarded without changing line numbers; other
conditional blocks remain unknown. Multi-line attributes whose opening
anchor is not a changed line also remain unknown.

The separate `schemaVersion: 1` cohort is
`redundant-coverage-v2-preview-cohort`; its rule, model, and config bindings
cannot be substituted with Owner or class-coverage identities:

| Field | Binding |
| --- | --- |
| `capability.id` / `rule.section` | `bpm-redundant-method-coverage@1` |
| `capability.digest` | `v1:sha256:1d9d2a3d8416b7004f6193043f8cfd43a6969d61bc9c18deb2e8fcc0c52d58ca` |
| `rule.path` | `src/DevPilot.OwnerCapability/Policy/redundant-method-coverage.v1.txt` |
| `rule.hash` / `rule.length` | `v1:sha256:3cecab1d5483531a1e899aa8ca71d999b96f1135a302193b1a34c72938b8d6df` / `220` |
| `rule.commit` | The immutable toolkit commit containing those policy bytes |
| `model.id` / `model.digest` | `none` / `v1:sha256:140bedbf9c3f6d56a9846d2ba7088798683f4da0c248231336e6a05679e4fdfe` |
| `config.id` / `config.digest` | `redundant-method-coverage-v1-user-approved` / `v1:sha256:53b2ef16e2190e33d6c96152eba1eb48a7f119dba312ceb438d71e534356a4bd` |

Replay uses `replay.modelRecords: []`. Live preview requires an explicitly
enabled read-only acquisition provider, with the pinned policy bytes from the
toolkit commit and complete normalized Azure DevOps discussion evidence. It
does not invoke a model or write to Azure DevOps. Raw private source and
discussion are never checked into this repository.

An in-memory, GET-only replay of a private active non-draft example at
iteration 7 pinned source
`13f48052d855d7c5c694e6297bd2ffc6648ad73f` and target
`c67b488c99acbd77caaaf1b7304ef3f50d9e77a6`. Its unique added
changed file produced **one eligible class and one class-level violation**
for **22 changed redundant attributes**, with the first posting anchor at
line 36 and a bounded sample of 12 method names. All 32 discussion threads
normalized; the exact current, unmarked human discussion reconciled the
whole class as `humanCovered: 1`, `wouldCreate: 0`, and `providerWrites: 0`.
The live generation was rechecked after the replay. No private source,
discussion text, or provider response was persisted.

An active unmarked human comment at **any** of the class's exact changed
attribute anchors that unambiguously explains the method attributes are
unnecessary because the class exclusion covers the entire class is
`humanCovered` for the **whole class**, even if its author is the configured
reviewer account. Only the rule-specific exact reviewer marker and body are
`noOp`. Ambiguous current discussions or matching prior-iteration threads
are `unknown`, not grounds for creating a duplicate comment.

Automatic posting has its own default-off configuration and signed bounded
create-only policy, independent from Owner and class coverage. A posting
candidate must recheck the active non-draft PR, immutable head/target, changed
attribute line, discussion snapshot and reviewer identity immediately before
creating a thread. No updates, thread resolutions, votes, status changes,
summaries, or notifications are authorized. This layer **does not enable**
posting, change a deployed task or policy, or write to Azure DevOps.
