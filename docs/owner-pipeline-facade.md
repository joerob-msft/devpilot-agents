# Owner pipeline facade: layer 1

This module is a small, provider-neutral boundary for a future Owner reviewer
stack. It does not replace or modify the deployed reviewer. Its production
shape is deliberately narrow:

```text
Acquire snapshot -> Build evidence -> Run capability
  -> Validate findings -> Preview -> Authorize delivery
```

The facade owns the order, bindings, normalization, validation, preview, and
authorization decision. Injected adapters own only acquisition, capability
execution, or delivery. No adapter is selected implicitly.

## Layer 1 contract

`New-OwnerPipelineBinding` creates an immutable identity that atomically binds:

- the review subject;
- the exact head;
- the rule set;
- the selected capability; and
- the authorization partition.

Every adapter response must echo the resulting binding ID. A mismatch stops the
pipeline before a later adapter can run.

Acquisition returns generic evidence units with stable IDs, explicit
`complete`, `incomplete`, or `unknown` states, and opaque JSON data. Capability
adapters return independently named assessments that can cover one or many
evidence units. This permits future cross-unit and relation-aware capabilities
without encoding a `(rule, file)` key or requiring one assessment per
construct. Relation-specific schemas are intentionally deferred.

The facade bounds unit, assessment, finding, diagnostic, text, JSON depth, and
JSON node counts. It accepts only JSON-shaped adapter data and normalizes it
without reinterpreting strings before crossing a stage boundary. Missing
assessment coverage remains `unknown`; it is never converted to a clear result.
An empty evidence set is also `unknown`; a later layer may add a separately
bound contract for an intentionally empty subject.

`unknown` dominates aggregate state. `incomplete` is used only when the facade
knows the input is partial; uncertainty about snapshot, capability, or unit
coverage remains `unknown`.

Delivery is a capability adapter, not a second reviewer. The facade always
builds a zero-write preview first, and it does not invoke the injected delivery
adapter unless the caller explicitly supplies `-AuthorizeDelivery`. Even then,
delivery is withheld unless validation is complete.

The public state vocabularies are:

- pipeline result: `complete`, `incomplete`, `unknown`, or `failed`;
- stage: `pending`, `running`, `complete`, `incomplete`, `unknown`, `failed`,
  or `skipped`; and
- delivery: `not-authorized`, `blocked`, `delivered`, `no-op`, `unknown`, or
  `failed`.

## Adapter seam

`New-OwnerPipelineAdapter` wraps a script block for one stage. A compatibility
adapter may call an existing reviewer process or read a replay fixture, then
translate its result into this contract. The facade does not copy, import, or
special-case the existing reviewer implementation. No layer 1 adapter has
built-in host access, model access, scheduling, or write authority.

Replay and live acquisition are peers: if they return the same normalized
evidence units for the same immutable binding, the evidence digest and all
later facade outputs are identical. Benchmark or corpus metadata stays outside
the production evidence boundary.

## Migration gates

Migration must proceed through all of these gates:

1. Run v1 and v2 in parallel against identical, pinned evidence and exact head
   bindings.
2. Keep only v1 eligible to write until review outcomes and failure behavior
   reach sustained parity.
3. Store v1 and v2 state under separate roots. Neither stack may repair,
   migrate, or reinterpret the other's state.
4. Keep rollback to v1 available without translating v2 state or replaying v2
   delivery attempts.
5. Do not delete legacy scheduling, acquisition, validation, delivery, or state
   plumbing until sustained equivalence has been demonstrated in production.

## Explicitly out of scope

This layer adds no scheduler, writer, Owner detection, provider client, model
runner, corpus projection, benchmark case, relation capability, deployment
switch, or live credential path. The existing V4 contract remains a
capability-specific contract and is neither widened nor forked here.
