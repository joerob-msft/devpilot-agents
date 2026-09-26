# Named arguments for changed MSTest `Assert.AreEqual` calls

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
The 525-byte policy is pinned independently at SHA-256
`008e56acc64ecdb92a2bcd4974bdaff85e23a9fdea610d1d055ddb88cf6aed61`;
the declaration and capability both reject a changed local policy.

Only a confidently resolved C# MSTest `Assert.AreEqual` invocation in a test
method, with an exact changed call opening line and at least one positional
argument, is actionable. Every supplied argument must be named according to
the overload (`expected:`, `actual:`, and any further supplied argument).
There is **one finding/comment per affected test method**, not one per
assertion. It anchors the first changed violating call and records up to 256
exact changed call lines with a bounded 12-line display sample. Unknown syntax,
binding, containment, or changed-line provenance is not actionable. The rule
does not reorder arguments or change assertion values.

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
The changed file has five additional non-allowlisted namespace imports, so
the file-only parser cannot prove its bare `Assert` binds MSTest. Its six
candidate method groups (26 calls, including the motivating line) therefore
remain **unknown**, with zero actionable findings and zero `wouldCreate`.
This is not a measured live `humanCovered` outcome: current unmarked human
discussion covers a method only when its MSTest call binding is known.
No private test code, discussion text, or provider response is stored here.
