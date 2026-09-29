# Bounded rule evaluation from active-PR intake

`tools/Invoke-BoundedRuleEvaluation.ps1` is a **separate, default-off,
read-only** scheduler-callable command. It does not register a task, enable
any service policy, post comments, vote, set statuses, update threads, or
send notifications. It leaves the pinned Owner and static read-only relation
cohorts and their attempts untouched. Relation has no writer or automatic
evaluation path here.

The command needs absolute external `-StateRoot`, `-IntakeConfigPath`, and
`-ConfigPath`. The intake configuration must be the exact configuration
used to create `active-pr-intake-v1/cohort.json`; the dispatcher checks its
SHA-256 binding, complete inventory, per-head declarations and changed-line
evidence, and byte-for-byte equality with the immutable generation. Intake's
two-pass ADO listing cannot provide an atomic server snapshot. Changed-line
proofs are necessary but **not rule evaluations**. A selected head without
complete line evidence is `unknown`, never `evaluated`. The intake timestamp
must be current (at most 120 minutes old in the sample), or dispatch fails
before reading ADO.

Optional test-project ownership receipts are described in
[`test-project-scope-evidence.md`](test-project-scope-evidence.md). A complete
source-head-bound receipt is an additional prerequisite for the dormant `@2`
all-class coverage capabilities: dispatch re-reads the graph through
Changes and binds its digest in the declaration and observation. An absent,
partial, mismatched, or mixed-owner receipt stays unknown, and neither the
intake receipt alone nor an old observation counts as evaluation. `@1`
MSTest rules retain their existing source and changed-line semantics.

The sample [`rule-evaluation.config.json`](../samples/rule-evaluation.config.json)
has both global and per-capability switches disabled. To run an enabled
configuration, the operator supplies `DEVPILOT_RULE_EVALUATION_KEY` outside
the repository and an external `signature` of the form
`v1:hmac-sha256:<lowercase-hex>` over the UTF-8 bytes of
`ConvertTo-AgentCanonicalJson` of the configuration without `signature`.
Neither the key nor private ADO content belongs in the repository. There is
no implicit enablement through the intake setting or any existing signed
writer policy. `-Run` and a valid signature are both required. Disabled
invocations do not contact ADO or create durable dispatcher state.

At most 20 eligible master-target heads are selected per invocation, in
numeric-PR order with an atomic durable next-ID cursor. This includes old
PRs: on a stable 275-head eligible inventory, every head is offered a slot
within 14 cycles. Heads that change source, target, iteration, status, or
draft state between intake, pre-read, and post-read are unknown rather than
credited; failed reads and unavailable/over-budget evidence are separate
reasons. The cursor advances only with a committed immutable report, so a
crash before commit repeats a batch. An exclusive per-dispatcher file lock
prevents concurrent runs from sharing a cursor. Every run mints a fresh
generation under `rule-evaluation-v1/generations/`, and only observations
minted for that generation under `rule-evaluation-v1/observations/` can count
as evaluated. Previous generations never become current-head coverage,
even when the PR ID is the same. A newly changed head has to be read again.
The latest report is swapped atomically after observations and its immutable
generation are durable.

Each enabled rule receives its own new immutable
`rule-evaluation-v1/declarations/<digest>.json` with the generation,
intake declaration/line-proof digests, exact source/target/iteration,
configuration and per-rule cap. Each enabled deterministic capability
(class exclusion, redundant method
exclusion, and named `Assert.AreEqual` arguments) uses the repository's
bounded C# parsers against exact-commit source and changed spans. Its
immutable observation records the intake generation, exact source/target
commits, target ref, iteration, rule identity, rule declaration digest,
timestamp and aggregate outcome. The independent per-rule cap and global
cap both apply. Unknown
parser resolution or a cap excess cannot become a finding. Before recording
would-create counts, each enabled deterministic rule must carry a signed
`binding` with `ruleRepositoryId`, `rulePath`, `ruleCommit` (40 lowercase hex),
`ruleHash` (`v1:sha256:` of the repository-owned policy text), and
`capabilityDigest` (the repository-owned capability version). The path must be
the corresponding `src/DevPilot.OwnerCapability/Policy/<rule>.v1.txt`; the
capability digest is `v1:sha256:` of the UTF-8 policy basename followed by
`-capability-v1` (for example, `named-areequal-arguments-capability-v1`).
The dispatcher checks the local policy hash. A missing or changed binding fails
closed; the sample intentionally leaves rules disabled and has no live rule
commit to infer. The rule commit and repository ID must be the **actual pinned
rule source** used by the reviewer; signing invented values will not match
existing markers. No rule pin is inferred from the BPM PR head.

The command reuses the repository's ADO discussion normalizer and OwnerCapability
marker/body and reconciliation code per class or method group: duplicate
comments are deduplicated; an unmarked same-account comment is human, not
automation. Only a current exact marker/body/anchor is `noOp`, current exact
unmarked human coverage is `humanCovered`, and an absent relevant thread is
`wouldCreate`. Stale, moved, closed, or ambiguous discussion is `unknown`.
The immutable observation stores only digest-bound per-finding classifications,
counts (`findings`, `noOp`, `humanCovered`, `wouldCreate`, `unknown`) and a
normalized discussion digest, not source or comment bodies. These are
**read-only hypothetical outcomes**, never posting authority.
Source text and comment bodies are transient and are never written to the
cohort, observation, or normal log.

Owner remains separately default-off. Enabling Owner in the signed dispatcher
configuration requires a `binding` with `ruleRepositoryId`,
`rulePath: documentation/EngineeringProcesses/Conventions/AutomatedTests.md`,
`ruleSection: "## Claim ownership"`,
`ruleCommit: f6db83436b48f48a8521095a888d79f67823bbb2`,
`ruleHash: v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f`,
the exact positive `ruleLength`, a pinned `capabilityDigest`, and a
`model` object with the selected `id` and `digest` (`v1:sha256:` of the
UTF-8 model ID). The authoritative section bytes must be supplied separately
and checked against
that binding; a repository-local substitute or missing bytes cannot become
an Owner evaluation. An absent evaluator remains
`owner-evaluator-unavailable`. An evaluated Owner result must bind a fresh
one-entry manifest to this intake generation and rule declaration, prove a
completed no-write execution, and report every finding separately. Neither
an old pinned Owner observation nor the aggregate thread counts count as
current-head evaluation.

The repository wrapper builds the evaluator itself; it no longer accepts an
operator-supplied `-OwnerEvaluator` scriptblock. With Owner enabled in the
signed configuration, `-OwnerRuleBytesPath` identifies the exact externally
acquired remote policy section bytes (absolute path outside the repository, no
reparse point, at most 64 KiB). `-EnableOwnerLiveModel` is a separate manual
opt-in; `-OwnerModel` and `-OwnerCredentialEnvironmentName` must select the
explicit configured model and an allowed credential environment name. Missing
or mismatched bytes, provider identity, or model configuration yields an
explicit Owner unknown, not a synthetic Owner completion. The existing Owner
v2 live orchestrator provides a no-tools, isolated model process, read-only
provider, bounded lease/retry, and immutable completed record under the
private external `active-owner-evaluation-v1` state root. The dispatcher
supplies its already-budgeted discussion response to the Owner adapter;
there is no second unaccounted ADO discussion read. Source is not written in
this repository or normal output. An operator must separately acquire and
verify the pinned remote policy section and configure the live model; this command
does not supply credentials, signed live configuration, or an active intake
generation.

`tools/Invoke-PrivateCanaryIdentityDiagnostic.ps1` is a separate default-off
diagnostic for an explicitly authorized Identity check. Without
`-VerifyGraph`, pass
the organization slug and expected reviewer UPN with `-Run`; it obtains an
in-memory AAD bearer, makes **one bounded GET** to `connectionData`, and
stops on both success and failure. It returns only a fixed reason, minimal
verified/unknown state, and GET attempt/write counts. It does not create
private state, read projects or source documents, sign intake, evaluate rules,
or authorize any model or writer. A verified Identity response alone is not
source, cohort, or rule qualification; the command must not be used as a
substitute for the signed-intake and evaluation gates.

With a separately authorized `-VerifyGraph -Run`, the same diagnostic
uses at most three GETs under one in-memory bearer: token-bound
`connectionData.authenticatedUser` followed by a Graph user and Graph
storage key for its exact subject descriptor. It requires the
authenticated user's storage-key GUID and subject descriptor, the Graph
user's matching descriptor, user kind, and principal name matching the
expected UPN, and a storage-key GUID matching the authenticated user's
GUID. `uniqueName` is optional in the connection response but, if present,
must match the expected UPN. Missing or inconsistent proof stops before
subsequent reads; only fixed status/reason and attempted GET count are
returned. An identity proof does not authorize source/intake/evaluation
reads or any write, and each live use requires its own explicit approval.
The CLI validates its fixed, Int64-safe JSON result before emitting it; it
does not persist observations. An uncaptured result cannot be reconstructed
by retrying under an exhausted GET authorization.

`tools/Discover-PrivateCanaryMergedMaster.ps1` is the separate **default-off,
stateless discovery** command. With an explicitly authorized single operator
and `-Run` it uses one freshly acquired bearer for bounded GETs only. It accepts
the user-approved `-Organization`, `-SourceProjectName`,
`-SourceRepositoryName`, and `-SourcePullRequestId` as invocation inputs in
memory, validates their shapes and the reviewed PR ID before any GET, and
uses ADO's same-bearer repository GUID, completed PR, merge, master and raw
document proof to reject a wrong target. It does not read or create a
selector/key file, private root or authority pin; these invocation fields
are not themselves durable approval. Only the designated operator may run
it after a fresh explicit handoff. Before invocation, the operator must
independently compare the exact in-memory selectors with the user-approved
source URL. Shape, organization consistency and reviewed PR ID fail before
GET; a plausible but wrong project or repository can consume bounded GETs
to the fixed host before the GUID/content proof rejects it, never creating
state or approval. Never place live selector values in child-process
arguments, shell history, transcripts, CI, or logs. An authorized operator
can instead import the module in one persistent process, collect values
through masked non-history input, and pass them directly to the exported
discovery function; if confidential input cannot be ensured, stop. The
tracked `samples/private-canary-source-selector.example.json` contains only
fictional placeholders and cannot serve as production authority. The sample
hygiene check scans nested sample JSON and rejects production-looking bare
source names and both modern and legacy ADO URL forms, including org-scoped
and project-scoped `_git` and `_apis` routes. Subsequent
gated production invocations verify a
`v1:hmac-sha256:` signature over the canonical JSON of the five unsigned
fields, binding the organization, project and repository in memory. The key file
contains exactly 64 base64 characters encoding 48 random bytes; neither
file nor any raw selector value belongs in tracked artifacts, command output
or logs. Those external ACL-private files must be created only after
independently reviewed discovery/source proof and separately authorized
private artifact preparation; their key must be random. Supplying a signed
selector does **not** itself authorize live GETs:
the coordinator must separately review and designate the operator and exact
head. The invocation organization must match. The repository GUID is derived from the
same-bearer repository GET and checked against PR, commit, and item evidence.
Discovery checks
ConnectionData/Graph user/storage-key identity against the in-memory Azure
CLI user UPN, and attests the completed reviewed PR, immutable merge commit,
current master ancestry and exact ref, and raw Git item/blob at the reviewed
candidate commit, merge commit, and current master. The candidate document
must match the independently reviewed SHA-256 and byte length below. Merge
and current-master raw bytes must be byte-identical to that candidate, and
the distinct class/redundant section and policy-line hashes must agree.
After rechecking PR/ref/identity it returns only immutable commit, blob,
document, section, line, and recomputed merge-commit declaration digests
marked `discovered-merged-source-no-state`: no path, raw payload,
account, token, header, private file or state, signing, or write. Any byte
or section change, incomplete ancestry, drift, or throttle stops without a
pin; changed content cannot be auto-approved. Discovery proves source
continuity in memory but **does not** create a durable pin or activate a rule.

`tools/Provision-PrivateCanaryMergedPin.ps1` is a separate **default-off,
source-only** provisioner; this public layer does not authorize running it
against a live service. The user's accepted private source URL supplies the
organization, project, repository, reviewed PR and document selectors in
memory (or CLI parameters on a trusted machine without command-line history
or logging). The module entry point accepts a three-field route in memory;
the reviewed PR ID and document path must exactly match the repository-owned
contract before account access or any GET. No pre-existing signed selector,
private selector key, human RSA key, or public approval-signature release is
required for this **GET-only** source binding.

Before any new private directory or key, the provisioner validates those
exact input selectors, then performs a **fresh stateless**
completed-PR, merge/current-master ancestry and raw candidate/merge/master
document proof with class/redundant section, line and declaration hashes. It
also checks the signed-in work principal and Graph user/storage key on the
same bearer before and after source reads. The candidate's immutable commit,
document SHA-256 and length remain pinned independently; the completed PR,
actual repository GUID, merge commit, current master, blob, section, line
and distinct merge-bound declarations must all prove consistent. No source
SHA is assumed to equal a squash/rebase merge SHA. Any drift or throttle
stops with **no** new private root and no retry. Only after those checks does
it generate separate random selector and pin integrity keys, write both the
signed selector and merged-pin envelope into a newly created ACL-private
external staging directory, validate all four files, and rename the
directory into place. The resulting selector/key and pin/key are the
inputs for later gated read-only consumers; their HMACs protect private
artifact integrity, not independent human source approval. On a partial
failure it cleans only a newly attributed,
exactly named contained directory; an existing or aliased target is never
overwritten or removed. Success reports only fixed state and read/write
counts, not selectors, identity, source text, hashes, signature, key, or path.
No POST, comment, model, intake, Owner/Named proof, or writer authority is
part of this operation. The HMAC protects the private pin's integrity; it is
not an independent approval or posting credential. Its output is source-only,
not a completed canary evaluation. Do not run this provisioner for real or
prepare real files without a subsequent explicit sole-operator artifact
handoff and fresh exact-head CI. Owner/Named remain separately unapproved.

`tools/Invoke-PrivateCanaryMergedPreflight.ps1` is the separate **stateless**
read-only merged-master source gate, disabled without `-Run`. Its repository-owned
`MergedMasterPin` is intentionally **unset**.
Keep actual source selectors, merge commits, document and rule digests, and
private keys out of public source, tests, samples, PR descriptions, and CI.
The merged source must be supplied through a version 1 ACL-private HMAC
envelope and key created only after the fresh source proof above. Without
these external trusted files, `-Run` fails `merged-master-pin-unavailable`
before any ADO request. Never promote a synthetic fixture, a previously
reviewed *source* commit, or an assumed squash/rebase blob into merged
provenance. Pin validation requires
the **same independently reviewed candidate document digest and length**,
while section/line hashes are verified against those exact bytes and the
merge-commit-bound declaration digests are recomputed. No live ADO GET or
private state is authorized by these generic public changes.
The preflight, bootstrap, registry, signed-intake and evaluation commands
require the same external selector/key and reviewed merged-pin/key paths on
`-Run`. The pin envelope has exactly `schemaVersion: 1`,
`kind: private-reviewed-merged-master-pin`, `selectorSignature`, `pin`, and
`signature`; the latter signs the canonical JSON of the four unsigned fields
with a separate random 48-byte key encoded as 64 base64 characters. The
envelope HMAC and selector signature must verify against their private keys
and the user-approved source selector. A missing, changed, unsigned,
mismatched, or previous-version
envelope fails before source GETs or state. The
stateless discovery command instead uses only its in-memory selector
arguments and needs no private files before source proof.

`tools/Initialize-PrivateActivePrCanaryInputs.ps1` is a **preparation-only**
bootstrap for the private syntactic canary. It is disabled without `-Run`;
it requires a new absolute external `-StateRoot`, the expected organization
slug, and BPM project/repository names. The production commands read the
signed-in Azure CLI **user** account UPN in memory from `az account show`,
validate its work-account shape, and never print or persist that selector.
With `-Run`, it acquires one AAD bearer in memory via `az account get-access-token`,
uses bounded GETs only, and checks the connection identity before and after
the source reads. Both checks bind the authenticated account GUID and subject
descriptor to the Graph user (whose principal name must equal the expected
CLI UPN) and Graph storage key under that same bearer. The ADO `uniqueName`
is optional; if present, it must agree with the expected UPN, and it is never
invented from the Graph principal name or descriptor. It derives the
project/repository GUIDs and account ID/descriptor from those GETs. It checks
the approved source project/repository
identity, completed PR 17307009 targeting `refs/heads/master`, its reviewed
source commit against the latest iteration, independently pinned immutable
merge commit, and the current exact master ref/commit. A bounded ancestry
walk proves the merge commit is reachable from today's master, even when
master advanced; exhausted or incomplete history is unknown. It reads the
merge and current-master item and raw UTF-8 Git blobs independently, verifies
their Git object IDs, and requires byte-identical content matching the
independent document digest, length and blob pin. Both rule-specific line,
section and declaration digests must match independent pins. The PR and
master ref and Graph-bound account are rechecked on the same bearer before
any state is created; every signed intake and evaluation repeats this source
proof and final rechecks. A deleted PR source branch is not required, and a
source SHA is never mistaken for a squash/rebase merge SHA. The Owner and
named-parameters sections are
independent approvals at the Owner commit. The class and redundant rules
have distinct versioned declaration digests for lines 221 and 223 of the
**merged** document; their receipts bind both immutable merge commit and
the current exact master commit. The named-rule
local policy is bound to the checked-out repository commit and byte-identical
Git blob, not misidentified as a remote or BPM policy. No raw source, token,
or alias secret is written into the repository or normal command output.

The inherited Owner/Named commit and section pins were not independently
reviewed against this corrected source repository. A separate repository-owned
Owner/Named review gate remains **unset**, so bootstrap and registry stop
before GET or state even after a merged coverage pin is separately reviewed.
When separately approved, they must additionally prove the Owner commit in
the approved source repository's bounded current-master ancestry, its raw Git blob/object ID,
and byte-identical pinned Owner and Named sections at that commit and the
current master. The class/redundant merge proof cannot substitute for this
independent Owner/Named authority.

After all checks it creates only `provider-config.json` and
`approved-sources.json` in a fresh ACL-private external directory. The latter
is a version 6 `private-merged-master-canary-sources` four-rule source
**receipt** plus a separate named-section
entry. It is **not** the legacy approval manifest consumed by
`Invoke-ActivePrCanaryQualification.ps1`. There is no HMAC key, signed
dispatcher config, intake, canary GET evaluation, model call, or provider
write in this preparation layer; do not feed these receipts to the old
`@1`-only command. Master provenance is **read-only source authority**, not
writer permission. Do not run the private bootstrap until its own and parent exact-head CI
and input provenance have been checked.

`tools/Invoke-PrivateCanaryRuleRegistry.ps1` consumes **only** that
bootstrap's external ACL-private `provider-config.json` and version 6
`approved-sources.json`. It is disabled without `-Run`; it never creates
private state, signs configuration, selects PRs, evaluates rules, invokes a
model, or writes to ADO. When explicitly run after the exact-head CI and
source gates, it obtains one AAD bearer in memory and performs at most 120
bounded GETs. It checks the BPM and approved source identities, independent Owner and
Named section bytes against their raw Git blobs, the two distinct merged
declarations at the immutable source merge commit and today's master blob,
the completed PR and exact master ref before and after the source reads,
the full GUID/descriptor/Graph user/storage key principal proof before and
after, and the locally pinned Named policy blob.
It returns four **disabled**, separately digest-bound rule entries and
`verified-not-evaluated`, not a writer-approved rule. A receipt field cannot
substitute for a fresh read; changed or missing
receipts and source drift fail closed. Do not persist or treat this output
as proof of changed-line evaluation, ownership, thread reconciliation, or
Owner no-tools execution.

`tools/Invoke-PrivateCanarySignedIntake.ps1` is the **next default-off,
preparation-only** layer. It accepts only the ACL-private external bootstrap
`provider-config.json` and version 6 `approved-sources.json`, a new disjoint
absolute external `-StateRoot`, and one or two explicit `-CanaryPullRequestIds`.
`-Run` revalidates the registry and approved source merged/current-master blobs
before and after intake; changes to the receipts or provider identity abort
signing. The intake provider verifies the CLI/AAD principal and project/repo
binding, permits only GETs, and requests raw blob/project-tree evidence for
selected changed C# files. Its opt-in created-time keyset listing fixes a
single UTC upper bound across two full active-PR passes, asks for one
lookahead entry per page, and rejects order drift, ambiguous timestamp ties
at page boundaries, truncated pages, missing selections, and mismatched
passes. ADO has no atomic inventory snapshot: active/draft changes during
listing can still make the attempt unknown; no evidence is credited from
such an attempt. All active PRs, including drafts, count in the inventory;
only the explicit non-draft master-target selections receive changed-line
and complete project-scope receipts. Nonselected and out-of-policy heads
remain pending/skipped, never evaluated.

The signed invocation obtains **one AAD bearer** and uses it with a
redirect-disabled client for the registry's source proofs, the intake's
ConnectionData/Graph account proof, project/repository metadata, PR inventory,
commits, trees, raw blobs, changes, and discussions, and the final registry
recheck. No `az devops invoke` credential or descriptor-derived UPN participates
in this path. Every request is a bounded GET; HTTP throttling stops rather
than retries, and failures before signing leave no new external state.
The v5 signed intake/config and registry bind the v6 identity/source receipt
and exact head/iteration evidence; previous v2/v3/v4 signed handoffs are rejected by the
runner, not silently promoted to merged authority.
The independent runner obtains one fresh bearer for its own registry/source
recheck and subsequent read-only evaluation, not a replay of a bootstrap
bearer. Its initial and final account proofs must agree with the signed
immutable identity.
Only the immutable account GUID and Graph subject descriptor appear in the
v6 receipt, private provider config, v3 intake config/generation, and v5
signed dispatcher. The current approved CLI UPN is freshly read into memory
for **each** bootstrap/registry/signed-intake/runner invocation, checked
against same-bearer ConnectionData (if it reports `uniqueName`), Graph user
principal name, and Graph storage-key GUID, and never written to files or
normal output. No raw UPN, ADO alias, Graph principal name, or unkeyed alias
hash is included in any signed artifact. During discussion classification
only an ADO `uniqueName` actually supplied by token-bound ConnectionData is
passed in memory as the reviewer alias; the CLI UPN/Graph principal name is
never substituted when that alias is absent. Matching immutable GUID and
Graph descriptor can establish human coverage without an alias; when a
verified ADO alias exists, a conflicting author alias remains unknown rather
than human coverage. Alias presence and value must remain stable within an
invocation, but need not match an earlier receipt that deliberately omits it.

The two-pass inventory and selected-head changed-line/project-graph evidence
are assembled in bounded memory. Unknown inventory, incomplete selected
graph, changed head, source/identity drift, or throttle abort before creating
any signed-intake root, lock, generation, file, or key. Only after complete
intake and a second source/head/account check does the command create the
fresh ACL-private root, persist the immutable intake generation, copy the
verified provider JSON and four-source manifest, mint a random HMAC key, and
sign `canary-dispatcher.json` over the repository canonical JSON
representation. It also writes the exact intake config. The signed handoff
binds each selected source/target/iteration, changed-line/project-scope
digests, and four **distinct, disabled** source declarations. The class/redundant
bindings have **merged-master read-only** provenance. This config has
`enabled: false`, `writerEligible: false`, and `modelEnabled: false`; it is
**not** accepted by the older `@1` dispatcher and must not be enabled or
hand-signed to bypass the independent `@2` runner. Its output is
`signed-intake-not-evaluated`, with zero evaluated/humanCovered/wouldCreate
and Owner unknown. The key and private source stay outside the repository
and normal output. Do not run this against the private service until this
layer and its parent stack layers have green checks at their exact heads,
the completed source PR, master ref, and both blobs are reconfirmed, and a separately authorized
operator owns the live GET budget.

`tools/Invoke-PrivateCanaryEvaluation.ps1 -StateRoot <private-external-root>`
is default-off and does not open the root until `-Run` is specified. The
root must be the ACL-private output of the signed-intake tool above, not a
repository file or a new configuration. On `-Run`, the runner verifies the
canonical unsigned HMAC, all five private input files, the unchanged
immutable intake generation, exact selected heads and evidence digests,
and the freshly verified four-source registry. It rechecks the source's completed
PR, immutable merge commit, current master ancestry/ref, and both raw Git
blobs; it never accepts a stale candidate receipt. The selected active,
non-draft master-target
heads require current changed spans and complete source-commit-bound
project-ownership evidence before either `@2` coverage parser can run.
Named Assert uses its separate local policy binding. Owner is always
`unknown`/not evaluated; this command never invokes a model.

The GET-only provider requires the API's complete bounded all-threads
response (the threads endpoint has no documented server-side pagination),
rejecting count mismatches and unexpected continuation. The discussion
adapter checks distinct threads/comments and splits the response into
bounded local pages. For each selected head, the runner reconciles
per-finding body/marker/anchor against the current discussion snapshot and
then re-GETs discussions and the exact source/target/iteration before
returning. The author is same-account only when the comment's valid GUID
and descriptor both match the authenticated GUID and Graph subject descriptor;
an absent ADO `uniqueName` does not turn Graph principal name into a comment
alias. A known ADO alias conflict, incomplete or contradictory immutable
fields, or conflicting optional descriptor evidence is ambiguous, never
foreign or sufficient for wouldCreate. Only fully valid, different GUID
**and** descriptor evidence is foreign. Same-account unmarked comments can
count as human coverage; only an exact current-generation automation marker
can count as automation. Outdated or duplicate candidates remain unknown.
The summary reports per-rule `evaluated`, `unknown`, `humanCovered`,
`wouldCreate`, `pending`, and `skipped`, plus draft exclusions and the
immutable intake generation. These are hypothetical, merged-master
read-only observations, **not** authority to write, vote, notify, mutate
policy/tasks, or enable relation. Live private ADO execution remains
gated on exact-head green CI for this PR and its parents and fresh
source/head/identity verification; synthetic/local tests are the default.
No `@2` posting follows from this proof or `wouldCreate`: a distinct signed
`@2` delivery path, deployment authorization, and current head/discussion
rechecks would require separate work.

For the existing **private syntactic `@1` canary only**, use
`tools/Invoke-ActivePrCanaryQualification.ps1` instead of hand-signing a
configuration or fabricating a cohort. Its `-Run` switch is default-off.
It accepts one or two explicit `-CanaryPullRequestIds` and a **new**, absolute
external `-StateRoot`. It reads an existing private ADO provider config from
`-ProviderConfigPath` (with `provider: AzureDevOps`, `repository.organization`,
`repository.project`, `repository.name`, `repository.id`, and
`operator.defaultAlias`) and a separately approved external rule-source
manifest from `-ApprovedSourcesPath`. Both files must be private and outside
the repository. Optional `projectId` and `expectedAccount` in the provider
config are checked against GET results; otherwise the tool derives the exact
GUID/descriptor/UPN with read-only project, repository, and connection GETs
and checks the authenticated account against `operator.defaultAlias`.

The approved source manifest has keys `owner`, `namedSection`, `class`,
`redundant`, and `named`. Each entry must explicitly set `approved: true`,
`projectName`, `repositoryName`, `repositoryId`, `commit`, and `path`. The Owner
entry must pin the independently approved source's
`documentation/EngineeringProcesses/Conventions/AutomatedTests.md`
at `f6db83436b48f48a8521095a888d79f67823bbb2`; the other three entries
must independently identify their *actual approved* policy source commits
and the corresponding
`src/DevPilot.OwnerCapability/Policy/{test-class-coverage,redundant-method-coverage,named-areequal-arguments}.v1.txt`
paths. The tool fetches each pinned source via GET, checks local policy
bytes against the remote policy bytes, verifies the Owner section digest
against its fixed SHA-256, and records both Owner and `## Named parameters for Assert`
section provenance. `namedSection` separately approves the named-parameters
section in the same document (and may pin the same commit as `owner`); approving
Owner alone does not approve that section. The CLI bearer identity and Azure
DevOps CLI identity must match before source reads; source text is read from
the immutable raw Git blob and verified against its item object ID, rather
than trusting the API's rendered `content` field. It does not attribute class
or redundant policy to the remote source. Missing approvals or mismatched content stop
provisioning; do not invent a commit or repository ID to satisfy the contract.
The named section is independently pinned to its 412 raw UTF-8 bytes
(`v1:sha256:b3935a2ac811353d1da72e9a310938679cf119963677bd2ebc90510aab85a03a`);
the trimmed Owner section remains a different digest at its own commit.

`Assert-CanaryCoverageSource` is a separate, **candidate-only** source
allowlist for the dormant `bpm-test-class-coverage@2` and
`bpm-redundant-method-coverage@2` rules. It takes two independently approved
external entries keyed by those rule IDs and a read-only `RuleSource` provider;
without `-Run` it returns disabled without making a source read.
Each entry must identify the independently approved source repository GUID,
project, immutable `AutomatedTests.md` path, reviewed unmerged source PR
head `7e6620ec40c9bc37c5a5e13d506053b0139c9206`, provenance
`unmerged-reviewed-pr`, full 16,286-byte document SHA-256
`68a5cb1aa2604b971c8c446c77ef50f74409407f65eaa2e9389acd636cddacee`,
and its own approved `v1:sha256:` declaration digest. The declaration digest
is SHA-256 of `ConvertTo-AgentCanonicalJson` over the rule ID, lower-case
repository GUID, commit, repository-relative path, enclosing `## ` section
heading/hash, and the appropriate policy line/hash (221 for class, 223 for
redundant). The two digests are distinct even though the document and section
may be shared. Use a provider constructed with `-VerifyReadPrincipal`: its
raw blob verification precedes this allowlist's document, section, and
declaration checks. No source text is returned or persisted.

This legacy function returns `immutable-candidate-only` and
`headVerified: false`. Its reviewed **source** bytes alone do not prove
current merged master policy. The merged-master bootstrap/registry reject
its old version 3 candidate receipt; the runner rejects old signed v2
configs even if re-signed. It does not grant `@1` or `@2` writer authority.

The tool then uses the intake provider's two complete bounded listing passes
over *all* active PRs, excludes drafts and non-master targets, and pins the
chosen subset's source/target/iteration and changed-line proof. A missing
candidate, incomplete inventory, or unknown selected line proof stops before
signing. Only then does it create a cryptographically random signing key,
private intake/config files, and an HMAC-signed evaluation config under the
new ACL-checked root. The dispatcher checks the signed canary pins against
the immutable intake generation before any evaluation GET. No CLI argument
or normal output contains the key, credentials, raw source, or discussion
bodies. The qualification tool **never runs the Owner model** (no credential,
model tool, or posting path): it reports Owner as `unknown/not-attempted`
and runs only deterministic class, redundant, and named rules. This is
read-only hypothetical `wouldCreate` evidence, not delivery authorization;
the signed config cannot grant posting. If a head or discussion changes,
the result is unknown and zero provider writes. A separate explicitly
authorized live-model qualification and delivery approval are still required
before any Owner evaluation or automatic comments.

The signed dispatcher enforces a 20-head batch, 32-finding ceiling,
configured ADO read/time budgets, and the Owner orchestrator's existing
bounded model process, evidence bytes, lease, and retry limits. It does not
expose independent signed per-head model-call, byte, time, or rate ceilings;
those would require a further orchestrator limit interface and signed
qualification configuration. This gap must be resolved before claiming
all-PR-scale live Owner evaluation.

The dispatcher repeats the active/non-draft exact-head and changed-line
checks after Owner execution, and repeats the discussion read to detect
concurrent edits. It rejects duplicated finding identities or inconsistent
per-finding counts. Owner results use the same immutable observation shape as
the other rules: a normalized discussion digest and classifications
`noOp`, `humanCovered`, `wouldCreate`, or `unknown`. These classifications
are read-only, **not** permission to create a comment. The dashboard requires
the signed source declaration binding and a completed no-write Owner proof
before crediting its current-generation counters. Class, redundant, and
named-argument rules still need their own separate signed live policies; this
change does not enable them or make relation writer-eligible.

The optional dashboard `roots.ruleEvaluation` /
`files.ruleEvaluationCohort` pair points to the private dispatcher root and
its `cohort.json`, respectively. The Rules view reports current-generation scope, classified finding counts,
evaluated, pending, skipped, unknown, and errors separately from
the pinned canary history. Configuration of this optional feed does not
deploy the dispatcher.
