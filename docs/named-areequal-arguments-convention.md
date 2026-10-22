# Named arguments for changed test-code `Assert.AreEqual` calls

`bpm-named-areequal-arguments@1` is an independent deterministic, model-free
review rule. Its authority is EngHub
`documentation/EngineeringProcesses/Conventions/AutomatedTests.md`, section
`## Named parameters for Assert`, at immutable commit
`f6db83436b48f48a8521095a888d79f67823bbb2`. The section's SHA-256 is
`b3935a2ac811353d1da72e9a310938679cf119963677bd2ebc90510aab85a03a`.
This is the SHA-256 of the **412 raw UTF-8 bytes** at offsets 6772 inclusive
through 7184 exclusive: from the `## Named parameters for Assert` heading,
including its trailing blank line, up to (but not including) the next `## `
heading. It says
multi-parameter assertions should name their arguments, especially
`Assert.AreEqual`, where reversing expected and actual compiles but changes the
assertion's meaning. This is **not** the EngHub Owner convention or either
coverage rule. The repository's short [rule policy](../src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt)
records the source pin without copying private test code or discussion.
The 653-byte local policy is pinned independently at SHA-256
`8b9fa35bd2bc96e9f0dbfc878806b540603ab4f255ddf41bf120311913b831f4`;
the declaration and capability both reject a changed local policy.

Only a confidently parsed C# test-method call spelled `Assert.AreEqual` with
at least two supplied arguments, an exact changed line within the complete
invocation, and at
least one positional argument is actionable. Ordinary namespace imports alone
do not change its call-site spelling or the named-argument style requirement;
the rule does not claim the receiver's resolved type is MSTest. Aliases,
receiver shadowing, and uncertain syntax or method containment remain unknown.
Every supplied argument must be named according to its actual overload. In a
conventional MSTest call these include `expected:` and `actual:`, but a
different overload may use other names.
There is **one finding/comment per affected test method**, not one per
assertion. It anchors the first changed violating call and records up to 256
exact changed invocation lines with a bounded 12-line display sample. When an
invocation starts outside the changed span, its first changed argument or
continuation line is the anchor; the complete call must still parse
confidently. Unknown syntax,
receiver shape, containment, or changed-line provenance is not actionable. The rule
does not reorder arguments or change assertion values.

The current-PR bridge accepts `devpilot-current-line-derivation-v1` evidence from
the shared intake. It derives that evidence from already-fetched source/target
content and the existing changed-span invocation, without another fetch or diff
pass. Complete whole-file C# deletions and same-path modified C# with zero current
spans can be filtered as known-empty for the line-only Named rule only when the
content proves no added lines: byte-identical content, CRLF/LF-only changes, or
retained source lines forming an ordered subsequence of target lines. The latter
comparison is bounded to 200,000 target lines and rejects NULs, bare carriage
returns, and changed final-newline presence. Nonidentical content requires a
complete target comparison bound to both commits, paths, actual source/target
UTF-8 SHA-256 digests, and byte lengths. The consumer revalidates serialized
records, including older `derivation-unknown` records, instead of trusting their
classification or empty spans.

Missing or inconsistent proof, real added lines, pure renames, binary or
truncated content, and cap-exhausted evidence remain UNKNOWN; zero spans alone
are not proof of compliance. Existing acquisition budgets, including the
5,000-line ceiling, remain unchanged. Derivation metadata participates in the
snapshot digest and acquisition identity, so old observations cannot qualify a
new binding. Named filtering creates a separate view without modifying the full
shared snapshot; it does not filter file-level rules or change the frozen Owner
view. This contract does not authorize delivery or change Owner body-coverage
semantics.

`tests/SafeZeroSpanSubset.Tests.ps1` exercises actual producer records after JSON
serialization and the Named consumer. Its additional frozen-evidence cases accept
`FrozenIntakeRoot` through `New-PesterContainer -Data`; the directory must contain
the private `file-progress` records for the motivating deletion-only and
line-ending-only changes. Those cases are explicitly skipped when the directory
is not supplied. Private content is never a committed fixture.
`tests/ActivePrIntake.Tests.ps1` also checks the shared producer through the
existing HTTP seam, including acceptance at 5,000 changed lines and UNKNOWN at
5,001; neither case raises the acquisition limit.

Fresh PR metadata remains uncached across head checks. Within one check, the
shared intake acquires one bounded ADO token and reuses the existing
authenticated in-process GET path for the PR, its iterations, and its exact
source ref. Status, draft state, latest iteration, and exact live ref are still
read and validated every time; only repeated Azure CLI process startup is
removed.

Preview accepts a separate `named-areequal-v2-preview-cohort`, signed source
and target generation, complete changed spans, pinned policy, and
`replay.modelRecords: []`. The rule's comment uses its own exact
`devpilot-named-areequal:v1` marker and stable body. An active unmarked human
request for named assertion arguments, **including from the configured
reviewer account**, covers its entire method. A prior-generation/outdated
discussion remains unknown, never evidence for a duplicate create. A bot
`noOp` requires the exact marker and current body at the current anchor.

Automatic delivery has a separate default-off `autoCreateNamedAreEqualComments`
setting, private key/root, signed bounded create-only policy and audit. A
candidate rechecks the active non-draft PR, immutable source/target generation,
exact changed-line anchor, reviewer identity and complete discussion before
creating a thread. The rule cannot update threads, status, votes, summaries,
notifications or relation evidence. **This implementation does not enable
delivery or alter the live reviewer, scheduled task, policy, or ADO state.**
Rules reporting distinguishes source implementation from verified deployment,
evaluation, and publishing authorization; another rule's counts or policy
never imply this rule ran.

Read-only revalidation of the motivating Azure DevOps example found an active,
non-draft PR at its original source/target commits and an active, unmarked
same-account human request on its exact changed call line. The provider exposed
that thread's comment as local ID 1; the separately supplied large comment ID
did not resolve, so this is not proof of that specific comment identifier.
With the syntactic call-site rule, an in-memory read-only replay of the
unchanged source/target generation recognized **six method groups and 26
positional calls** across the changed test file. All 18 discussion threads
normalized. The one-call group at the motivating line is `humanCovered` by
that current unmarked human request, with **zero `wouldCreate` for that
method**. Five other affected methods are distinct groups and remain
`wouldCreate`; the whole-PR aggregate is `humanCovered: 1`,
`wouldCreate: 5`, `unknown: 0`, `noOp: 0`, and `providerWrites: 0`.
This is parser plus manually bound, in-memory discussion reconciliation,
**not** a full facade run: the private installed config still identifies
another capability. It does not claim whole-PR zero creates.
No private test code, discussion text, or provider response is stored here.
