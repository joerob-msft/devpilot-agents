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
at least two supplied arguments, an exact changed call opening line, and at
least one positional argument is actionable. Ordinary namespace imports alone
do not change its call-site spelling or the named-argument style requirement;
the rule does not claim the receiver's resolved type is MSTest. Aliases,
receiver shadowing, and uncertain syntax or method containment remain unknown.
Every supplied argument must be named according to its actual overload. In a
conventional MSTest call these include `expected:` and `actual:`, but a
different overload may use other names.
There is **one finding/comment per affected test method**, not one per
assertion. It anchors the first changed violating call and records up to 256
exact changed call lines with a bounded 12-line display sample. Unknown syntax,
receiver shape, containment, or changed-line provenance is not actionable. The rule
does not reorder arguments or change assertion values.

Unknown parser outcomes retain only a bounded diagnostic enum and aggregate
counts. The fixed codes are `receiver-spelling-uncertain`,
`receiver-shadowing-uncertain`, `source-structure-uncertain`,
`call-shape-uncertain`, `changed-anchor-uncertain`,
`test-context-uncertain`, `symbol-identity-uncertain`,
`argument-segment-empty`, `argument-terminal-uncertain`,
`argument-leading-token-uncertain`, `named-argument-value-missing`,
`argument-count-insufficient`, `generic-angle-parse-uncertain`,
`same-line-call-ambiguity`, and `group-cardinality-exceeded`. Counts are exact
within the existing 200,000-token/line input bound, the array is emitted in
that order with at most 15 entries, and no source text, argument value, path,
exception message, or stack is included. The metadata is present only for the
exact `bpm-named-areequal-arguments@1` capability and rule and does not change
recognized state, outcome reason, anchors, completeness, or delivery.

The current-PR bridge accepts `devpilot-current-line-derivation-v1` evidence from the shared intake. It derives that evidence from already-fetched source/target content and the existing changed-span invocation, without another fetch or diff pass. Only same-path modified C# with complete, byte-identical source/target proof and zero current spans, or a complete whole-file C# deletion, can be filtered as known-empty for Named. Proof validation binds the head, actual UTF-8 content SHA-256 and length, path, change type, and exact inventory/span counts before filtering. Missing or inconsistent proof, derivation-unknown, pure renames, retained-file deletion-only changes, and malformed or unavailable relevant evidence remain UNKNOWN; zero spans alone are not proof of compliance. Derivation metadata participates in the snapshot digest and acquisition identity, so old observations cannot qualify a new binding. The frozen Owner runtime can consume a separately derived view that omits only proven identical C#; relation and other consumers retain the immutable full shared snapshot. This contract does not authorize delivery or change Owner body-coverage semantics.

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
