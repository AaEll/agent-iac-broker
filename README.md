# agent-iac-broker

The infrastructure-change plane for [Open Software Factory](https://github.com/AaEll/OpenSoftwareFactory):
the policy sets, the cost gate, and the Terraform modules that stand up a
gated-apply pipeline in a client's AWS environment.

An agent proposes infrastructure by naming a commit. A broker fetches that
commit, plans it, gates the whole plan, and applies it. The agent holds no
credential able to mutate anything.

- **[architecture.md](docs/architecture.md)** — the five systems and their boundaries
- **[contracts.md](docs/contracts.md)** — the API surfaces, verified against a running server
- **[policy.md](docs/policy.md)** — the rule catalog and how to write one

## Why a broker rather than credentials

A VPC bounds network reachability and nothing else. IAM has no general "confine
this principal to one VPC" condition — a subset of `ec2:*` actions honor the
`ec2:Vpc` condition key, while S3, IAM, DynamoDB, Route 53, and Bedrock carry no
VPC dimension at all — so "full access inside the agent's network" cannot be
written as a policy. AWS also has no synchronous spend cap: Budgets evaluate
against cost data that lags by hours, so a budget action bounds an overrun
rather than preventing one.

Brokering the apply answers both. Constraints IAM cannot state become plan
assertions, pricing the plan before apply turns a spend limit into a refusal,
and every change becomes a replayable diff against a revision rather than an
API call that happened once.

## The applier is Atlantis, not ours

The component holding the apply credential is the highest-risk code in the
system, so it is adopted rather than written. [Atlantis](https://www.runatlantis.io)
(Apache-2.0) already provides credential holding, plan storage, state locking,
a server-side policy gate, and — verified in the
[evaluation spike](https://github.com/AaEll/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-atlantis-evaluation-spike.md)
— a refusal to carry a policy approval forward across a changed commit.

What this repository owns is narrower: the rules, the cost gate, and the
deployment.

Two of its settings are invariants rather than options. `--enable-policy-checks`
is the difference between a gate and no gate: the spike's first run omitted it,
and a plan the policy refuses applied cleanly.
`--default-tf-distribution=opentofu` keeps the runtime on MPL-2.0 — Terraform's
BUSL-1.1 Additional Use Grant is a live question for a product that embeds it,
and OpenTofu is configuration-, provider-, and state-compatible.

## Two invariants

**The gate trusts no caller.** Policies are server-side. A request claiming
prior approval is ignored, and the gate runs regardless. A control that applied
on the strength of its caller's claim would be guarded by a remote assertion
rather than by itself.

**The gate sees the whole plan.** It evaluates the `tofu show -json`
representation, not a summary. An assertion such as "no security-group rule
opening port 22 to `0.0.0.0/0`" is not expressible against a summary.

## The gate is one layer, not the only one

The rules are public, which does not weaken them: a control that holds only
while its rules are secret does not hold. Behind the gate sit the agent
account's Service Control Policy, its concurrency quotas, a TTL reaper on the
run id, and a budget action — so a plan that slipped past a rule still meets a
ceiling it cannot argue with. Read the limitations as work to be done, not as a
route around the design.

## Development

```sh
python3 -m venv .venv && ./.venv/bin/pip install -e '.[dev]'
./.venv/bin/python -m pytest -q
./.venv/bin/ruff check .
```

## Status

Design and contracts are documented; implementation is in progress.

| Unit | State |
|---|---|
| Plan parsing (`agent_iac_broker/plan.py`) | Implemented, 37 tests, validated against real OpenTofu 1.13.1 output |
| Rule evaluation (`agent_iac_broker/gate.py`) | **Superseded.** Written before the spike, when the applier was going to be ours. The rules move to the rego sets in [policy.md](docs/policy.md); the module stays only until they land, and nothing depends on it |
| Rego policy sets | Specified, not yet written |
| Cost gate step | Specified, not yet written. Reuses the plan parsing |
| Terraform modules | Specified, not yet written |

### Known limitations

- **Region is not pinned by a rule.** A plan's region comes from provider
  configuration rather than `resource_changes`, so that check belongs to the
  Terraform invocation and the account's SCP.
- **Deletion is not scoped to the run.** Refusing destroys is all-or-nothing;
  refusing only the destruction of resources the run did not create needs the
  prior state's tags.
- **Refusals are matched as strings.** Atlantis signals a blocked apply with an
  internal message, not a stable code, so the image is pinned by digest and a
  contract test asserts the strings — see
  [contracts §1](docs/contracts.md#reading-a-refusal--the-one-contract-detail-that-matters-most).
- **Cost is a projection, not a forecast.** The ceiling judges the plan's
  post-apply steady state and cannot see usage-driven cost, data transfer, or
  per-request pricing.
- **Rules are AWS-specific.** Resource type names are AWS provider names.
