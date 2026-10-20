# AGENTS.md

Working agreement for agents contributing to `agent-iac-broker`. The design
rationale lives in the harness repository's
[architecture note](https://github.com/eFactory-ai/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-brokered-infrastructure-authority.md).

## What this is

The rules and the deployment for the only pipeline in the system able to mutate
infrastructure: the rego policy sets, the cost gate, and the Terraform modules
that stand up both planes.

Read that as the threat model. Every change here is a change to an authority
boundary, which is why this is a separate repository with its own review
history rather than a directory in the harness fork.

**The applier itself is Atlantis, adopted rather than written** — it already
holds the credential, stores the plan, locks the state, gates server-side, and
refuses to carry an approval across a changed commit. Do not reimplement any of
that here. See [docs/architecture.md](docs/architecture.md).


## Pull requests — small, meaningful, atomic

One coherent change per PR, small enough to review at a glance; branch →
commit → push → open a PR to `main`. Conventional commit titles (`feat`,
`fix`, `docs`, `chore`, `refactor`, `test`).

**Merge gates:** the GitHub Actions aggregate check `ci` must be green, and at
least one approving review is required. No force-push to `main`.

## This repository is public

Nothing here may be secret for the design to hold: a control that works only
while its rules are hidden does not work. That cuts both ways — **no deployment
configuration belongs in this repository.** No account identifiers, no real
ARNs, no client names, no allowlists or ceilings from a real deployment, in
code, fixtures, tests, or examples. Policy arrives as configuration at deploy
time. Fixtures use identifiers that are obviously invented.

## Security invariants (non-negotiable)

**The gate trusts no caller.** A request carrying any claim of prior approval
is ignored, and the gate runs regardless. Never add a parameter that lets a
caller assert a verdict, skip a rule, or supply its own policy. The policy is
deployment configuration, not request input.

**The gate sees the whole plan.** It evaluates the `terraform show -json`
representation, never a summary. A rule such as "no security-group rule opening
port 22 to `0.0.0.0/0`" is not expressible against a summary.

**The plan never reaches the caller.** The commit is the only input to the
privileged path. Never add a surface that hands a plan file to a caller to
apply later: that reopens the time-of-check-to-time-of-use window this design
closes. Atlantis closes it by re-planning and re-gating on every apply rather
than carrying an approval forward — preserve that property, and never cache a
verdict across requests.

**The policy override must stay unreachable.** A failed policy set can be
approved by an owner configured on the Atlantis server. That route is not
registered on the API, which is what makes every agent equally bounded. Never
expose it to a caller, and never add an owner an agent could act as.

**Deny by default.** A rule that cannot establish a change is permitted must
refuse it. The subtle case is Terraform's `after_unknown`: an attribute left
unresolved until apply must refuse, never skip. A skipped rule admits exactly
what it exists to stop. The cost gate follows the same rule — no estimate means
a non-zero exit, not a pass.

**The API secret is the entire access rule.** Atlantis's API carries no
per-request identity, so the token is the whole boundary: it buys plan and
apply and nothing more. It belongs only to the harness task role. Never derive
authority from a field a caller sends.

**Apply is idempotent.** Keyed on commit and session, so a retried supervisor
task reports the first outcome instead of applying twice.

## Testing

Every rule proves its negative case. A gate tested only on compliant plans is
untested, so each rule needs a fixture that violates it and an assertion naming
the rule that refuses it.

Keep the suite hermetic. Fixtures are real `tofu show -json` output generated
from configurations whose only providers are `null`, `local`, and `random`, so
a real plan and a real apply happen with no cloud credential and no spend. The
evaluation spike used exactly this technique; it is what keeps the tests
runnable in CI.

Real-cloud tests live outside this check and are run deliberately.

## Conventions

Python 3.11+, `ruff` (line length 100), `pytest`, `hatchling`. Type annotations
throughout, `from __future__ import annotations` at the top of each module.

Docstrings state contracts — preconditions, what a failure means, what a caller
may rely on — not narration of control flow. Name the refusal a rule produces
rather than describing the code that produces it.

## The contract with the harness

The surfaces are specified in [docs/contracts.md](docs/contracts.md): the
Atlantis HTTP API, the cost gate's exit code, the outcome record, and the image
digests the modules take as inputs. Nothing else crosses — no shared files, no
generated values, no imports.

They are published contracts: version them rather than reshaping a live one.
And note which way the Atlantis API runs — we *consume* it, so it is not ours
to change. Pin the image by digest, because a refusal is matched as a string.
