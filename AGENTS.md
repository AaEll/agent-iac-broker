# AGENTS.md

Working agreement for agents contributing to `agent-iac-broker`. The design
rationale lives in the harness repository's
[architecture note](https://github.com/eFactory-ai/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-brokered-infrastructure-authority.md).

## What this service is

The only component in the system holding a credential that can mutate
infrastructure. An agent proposes a commit; this service fetches it, plans it,
gates the whole plan, and applies it.

Read that sentence as the threat model. Every change here is a change to an
authority boundary, which is why this is a separate repository with its own
review history rather than a directory in the harness fork.

## Pull requests — small, meaningful, atomic

One coherent change per PR, small enough to review at a glance; branch →
commit → push → open a PR to `main`. Conventional commit titles (`feat`,
`fix`, `docs`, `chore`, `refactor`, `test`).

**Merge gates:** the GitHub Actions aggregate check `ci` must be green, and at
least one approving review is required. No force-push to `main`.

## Security invariants (non-negotiable)

**The gate trusts no caller.** A request carrying any claim of prior approval
is ignored, and the gate runs regardless. Never add a parameter that lets a
caller assert a verdict, skip a rule, or supply its own policy. The policy is
deployment configuration, not request input.

**The gate sees the whole plan.** It evaluates the `terraform show -json`
representation, never a summary. A rule such as "no security-group rule opening
port 22 to `0.0.0.0/0`" is not expressible against a summary.

**The plan never leaves the service.** The commit is the only input to the
privileged path, and the plan derived from it stays in storage the caller
cannot write. Returning a plan file for a caller to apply later reopens the
time-of-check-to-time-of-use window this design closes.

**Deny by default.** A rule that cannot establish a change is permitted must
refuse it. The subtle case is Terraform's `after_unknown`: an attribute left
unresolved until apply must refuse, never skip. A skipped rule admits exactly
what it exists to stop.

**Identity is not a claim to trust blindly.** The caller's session identity
arrives over the wire, which is acceptable only because the endpoint admits one
IAM role. Never widen that, and never derive authority from a field the agent
could influence.

**Apply is idempotent.** Keyed on commit and session, so a retried supervisor
task reports the first outcome instead of applying twice.

## Testing

Every rule proves its negative case. A gate tested only on compliant plans is
untested, so each rule needs a fixture that violates it and an assertion naming
the rule that refuses it.

Keep the suite hermetic. The gate is a pure function, and the service's tests
use a fake `terraform` on `PATH` with a local git fixture rather than real
Terraform or real AWS — that is what lets the time-of-check-to-time-of-use and
idempotency tests run in CI.

Real-cloud tests live outside this check and are run deliberately.

## Conventions

Python 3.11+, `ruff` (line length 100), `pytest`, `hatchling`. Type annotations
throughout, `from __future__ import annotations` at the top of each module.

Docstrings state contracts — preconditions, what a failure means, what a caller
may rely on — not narration of control flow. Name the refusal a rule produces
rather than describing the code that produces it.

## The contract with the harness

Two documented surfaces join this service to the harness, and nothing else:

- The HTTP API, versioned in its path (`/v1/...`).
- The container image tag the Terraform modules take as an input.

No shared files, no generated values, no imports. A change to the API is a
change to a published contract: version it rather than reshaping a live one.
