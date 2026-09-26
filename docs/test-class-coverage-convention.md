# Changed MSTest class coverage convention

`bpm-test-class-coverage@1` is a **separate user-approved repository
convention**, not a rule attributed to the EngHub Owner documentation. Its
versioned text is
[`test-class-coverage.v1.txt`](../src/DevPilot.OwnerCapability/Policy/test-class-coverage.v1.txt):
changed C# MSTest `[TestClass]` declarations require a class-level
`System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute`.
The versioned policy bytes have SHA-256
`3ddea91e113d37da4b4f08b20d072c13ca12b6a9c7cf451a338490e243b14467`
and length 132 bytes. This is a toolkit rule approved for this layer; it is
not presented as a published policy in the reviewed Azure DevOps repository.
The policy file is byte-pinned, including its CRLF terminator; Git must not
normalize its line ending on checkout.

The read-only facade consumes the existing bounded, source/target-bound file
and changed-span acquisition. The class capability checks the declaration and
its own attribute lists; unrelated methods and unchanged classes are not
conclusions. It records violations, compliant classes, and explicit unknown
assessments separately. It cannot use an Owner method finding or class
advisory as a coverage finding. A declaration anchor names the class on the
current source head. A marker and body are derived only by the trusted wrapper
from that exact bound class/rule identity. The model is not needed for the
syntactic rule: no model requests, model starts, or model write tools occur.
An unexcluded `partial` declaration remains unknown because another part of
the same type may carry the class-level attribute outside the changed files.

## Manifest and deployment boundary

The independent cohort is `schemaVersion: 1`,
`kind: coverage-v2-preview-cohort`, with the Owner-shaped bounded subject,
head, target, acquisition and declaration structure, but its own capability
root and rule:

| Declaration field | Exact value or constraint |
| --- | --- |
| `capability.id` | `bpm-test-class-coverage@1` |
| `capability.digest` | `v1:sha256:2307b3880530a8be4f1cbfbdd258673fb8e06e8b1bddd08613bbd641736a6658` |
| `rule.repositoryId` | Exact operator-configured toolkit repository identity |
| `rule.path` | `src/DevPilot.OwnerCapability/Policy/test-class-coverage.v1.txt` |
| `rule.section` | `bpm-test-class-coverage@1` |
| `rule.hash` | `v1:sha256:3ddea91e113d37da4b4f08b20d072c13ca12b6a9c7cf451a338490e243b14467` |
| `rule.length` | `132` |
| `rule.commit` | Immutable 40-hex toolkit commit that contains those policy bytes; pin it in the external manifest |
| `model.id`, `model.digest` | `none`, `v1:sha256:140bedbf9c3f6d56a9846d2ba7088798683f4da0c248231336e6a05679e4fdfe` |
| `config.id`, `config.digest` | `coverage-v1-user-approved`, `v1:sha256:7f0417f57898c7110ff342df5854f69404c95338c1a1815f2555b08bc8b59e9d` |

Replay uses `replay.modelRecords: []`. Live acquisition requires the explicit
host live switch (historically named `-EnableLiveModel`) and the read-only
provider, but does **not** require a model provider, credential, or model
launch. The provider must return the policy text from the pinned toolkit
commit, not substitute the Owner rule, and the complete Azure DevOps REST
discussion normalizer must bind the reviewer and current iteration. Never put
private Azure DevOps source or discussion text in this public repository,
model evidence, or a cohort manifest.

`humanCovered` means an active human text comment at the exact current class
anchor gives the unambiguous directive “exclude from code coverage” (optionally
prefixed with “please”, “kindly”, or “add”). It is neither
`noOp` (reserved for an exact reviewer-owned marker/body) nor `wouldCreate`.
An unmarked comment from the configured reviewer account is still human
discussion; account identity alone cannot prove wrapper authorship.
Ambiguous current context or duplicate matches fail closed as `unknown`.
Other mentions of exclusion, including negations and questions, remain unknown
rather than being labeled `humanCovered` or triggering an automatic duplicate.
Closed or deleted current threads and unrelated anchors do not cover a
finding. A matching prior-iteration discussion at the same file and within
two lines of a shifted class anchor is `unknown` requiring human review, not
`humanCovered` or auto-create; this protects the head-refresh case without
pretending the old anchor proves a current comment.
The same narrow rule for “add owner claim” on an exact method anchor protects
the independent Owner delivery path from duplicating a human request.

The automatic create-only setting and signed service policy are independent
from Owner's setting. They are **off by default** and must be enabled by an
operator after separate deployment validation. This PR does not change a
deployed task, enable a service policy, or post to Azure DevOps. The current
scheduled service remains a fixed cohort: this rule does not discover new PRs;
bounded active-PR intake is a subsequent layer.
