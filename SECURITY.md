# Security Policy

## Reporting a vulnerability

Please do **not** report security vulnerabilities through public GitHub issues.

While this repository is private and pre-release, report concerns directly to
the repository owner. If this project is later published under a Microsoft
organization, reporting will move to the Microsoft Security Response Center
(MSRC) at https://msrc.microsoft.com/create-report per Microsoft's coordinated
vulnerability disclosure policy.

## Threat model

This project runs autonomous agents that can read repositories, invoke a
language model, and — when explicitly enabled — modify and push code. Its
security posture rests on a small number of invariants. Treat a change that
weakens any of them as security-relevant:

1. **The model never selects its own work.** The wrapper binds exactly one
   unit of work per cycle and validates that binding on return.
2. **The tool ceiling is code-defined.** Configuration may narrow it and may
   never widen it. Pull-request and pipeline writes are denied to the model
   unconditionally.
3. **Every mutating capability is opt-in, defaults off, and is gated
   independently.** Pushing requires two separate flags.
4. **Protected branches are enforced in the wrapper** before push tooling is
   granted — not merely discouraged in prompt text.
5. **All pull-request content is untrusted input.** Titles, descriptions,
   diffs, and comments are data, never instructions. The model receives a
   structured metadata digest rather than raw comment bodies.
6. **The result marker is nonce-bound.** A marker that does not carry the
   per-cycle nonce, or that conflicts with another marker in the same output,
   is rejected.
7. **Environment-fault detection reads stderr only**, so repository content
   cannot forge an environment failure to escape failure accounting.

Please flag any change that erodes these in review, and call it out explicitly
in the pull request description.
