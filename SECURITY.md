# Security policy

This repository holds the rules and the deployment for a pipeline that applies
infrastructure changes on an agent's behalf. A flaw here can mean infrastructure
changed without a gate, so reports are welcome and taken seriously.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting** — the *Report a vulnerability*
button under this repository's Security tab. That opens a private advisory
visible only to the maintainers.

Please do not open a public issue for a suspected vulnerability. The rules in
this repository are deliberately public, but a *gap* in them is a live exposure
for anyone running the pipeline, and a public issue is a disclosure before
there is a fix.

Include what you would need yourself: the plan or configuration that reaches
the behaviour, which component you believe is at fault, and what an attacker
gets. A proof-of-concept plan is more useful than a description.

## What is in scope

- A plan that should be refused but is applied — a rule that can be evaded, or
  a gate that can be skipped.
- Any path by which a caller influences the verdict: supplying or weakening a
  policy, asserting prior approval, or reaching the policy override.
- A refusal that a client would read as a success.
- Credential exposure: the apply credential, the API secret, or the agent's
  role reaching further than documented.
- A Terraform module that grants more than its documentation states.

## What is not in scope

- **The published rules themselves.** They are public by design. A control that
  holds only while its rules are secret does not hold, and the rules are one
  layer among several — the account's Service Control Policy, its concurrency
  quotas, the time-to-live reaper, and the budget action sit behind them.
- **Documented limitations.** The gaps listed in the [README](README.md) are
  known and recorded. A report that one of them exists is not a vulnerability;
  a report that one is worse than documented is.
- **Vulnerabilities in Atlantis, OpenTofu, or conftest.** Report those to their
  own projects. A report that *our configuration of them* is unsafe is in scope
  — for example a setting we document as an invariant that turns out not to
  hold.

## What this repository must never contain

No deployment configuration: no account identifiers, real ARNs, client names,
or allowlists and ceilings from a real deployment, in code, fixtures, tests, or
examples. Policy arrives as configuration at deploy time, and fixtures use
identifiers that are obviously invented.

If you find any of the above committed here, that is itself a reportable issue.
