# agent-iac-broker

A policy-and-cost gated Terraform apply broker for agentic systems, part of
[Open Software Factory](https://github.com/eFactory-ai/OpenSoftwareFactory).

An agent proposes infrastructure by naming a commit. This service fetches that
commit, plans it, gates the whole plan, and applies it. It holds the only
credential in the system that can mutate infrastructure, and the agent holds
none.

## Why a broker rather than credentials

A VPC bounds network reachability and nothing else. IAM has no general
"confine this principal to one VPC" condition — a subset of `ec2:*` actions
honor the `ec2:Vpc` condition key, while S3, IAM, DynamoDB, Route 53, and
Bedrock carry no VPC dimension at all — so "full access inside the agent's
network" cannot be written as a policy. AWS also has no synchronous spend cap:
Budgets evaluate against cost data that lags by hours, so a budget action
bounds an overrun rather than preventing one.

Brokering the apply answers both. Constraints IAM cannot state become plan
assertions, pricing the plan before apply turns a spend limit into a refusal,
and every change becomes a replayable diff against a revision rather than an
API call that happened once.

The full rationale, including what the design accepts, lives in the
[architecture note](https://github.com/eFactory-ai/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-brokered-infrastructure-authority.md)
in the harness repository.

## Two invariants

**The gate trusts no caller.** A request claiming prior approval is ignored and
the gate runs regardless. A control that applied on the strength of its
caller's claim would be guarded by a remote assertion rather than by itself.

**The gate sees the whole plan.** It evaluates the `terraform show -json`
representation, not a summary. An assertion such as "no security-group rule
opening port 22 to `0.0.0.0/0`" is not expressible against a summary, and a
plan that travelled to the agent's side could be swapped after approval.

## The gate

`evaluate(plan, policy, estimate)` is a pure function: no process launch, no
credential, no network. Every refusal it can produce is therefore reachable
from a fixture, which is how the test suite covers the whole vocabulary.

Two properties shape it.

*Deny by default.* A rule that cannot establish that a change is permitted
refuses it. That covers a resource type absent from the allowlist, an attribute
Terraform leaves unknown until apply, and a required cost estimate that was not
supplied. The unknown-attribute case is the subtle one: Terraform marks values
it cannot resolve until apply, and a rule that silently skipped an unresolvable
`instance_type` would admit exactly the instance it exists to refuse.

*Every reason is reported.* Evaluation does not stop at the first refusal, so an
agent that fixes one violation does not discover the next a round trip later.

### Rules

| Rule | Refuses |
|---|---|
| `resource_type_not_allowed` | A managed resource type absent from the allowlist |
| `network_control_refused` | VPCs, gateways, route tables, peerings, endpoints — the agent may build inside its plane, not reshape it. Refused even when allowlisted |
| `instance_family_not_allowed` | An EC2 instance family outside the allowlist |
| `public_bucket_refused` | A false flag on `aws_s3_bucket_public_access_block`, or a public-read ACL |
| `admin_port_exposed` | Ingress from `0.0.0.0/0` or `::/0` covering an administrative port (22, 3389 by default) |
| `delete_refused` | Any destroy, when the deployment sets `refuse_delete` |
| `cost_ceiling_exceeded` | An estimate above the monthly ceiling |
| `cost_estimate_missing` | No estimate, where a ceiling applies |
| `cost_currency_unsupported` | An estimate in a currency the ceiling is not written in |
| `attribute_unknown` | An attribute a rule needs that Terraform leaves unknown until apply |
| `attribute_missing` | An attribute a rule needs that is absent |

### Using it

```python
from agent_iac_broker import CostEstimate, GatePolicy, evaluate_document

policy = GatePolicy(
    allowed_resource_types=frozenset({"aws_instance", "aws_s3_bucket"}),
    allowed_instance_families=frozenset({"t3", "m7i"}),
    monthly_cost_ceiling_usd=500.0,
)

verdict = evaluate_document(plan_json, policy, CostEstimate(monthly_usd=120.0))
if not verdict.allowed:
    for refusal in verdict.refusals:
        print(refusal)  # "aws_instance.huge: instance family p5 is not allowed [...]"
```

An unconfigured `GatePolicy()` refuses everything, which is the behavior a
half-configured deployment should have.

## Development

```sh
python3 -m venv .venv && ./.venv/bin/pip install -e '.[dev]'
./.venv/bin/python -m pytest -q
./.venv/bin/ruff check . && ./.venv/bin/ruff format --check .
```

## Status

The gate is implemented and tested. The service around it — `POST /v1/applies`,
taking a commit and a session identity, fetching, planning, gating, and
applying — is next, followed by the Terraform modules that deploy both planes.

### Known limitations

- **Region is not pinned by the gate.** A plan's region comes from provider
  configuration rather than `resource_changes`, so the allowlisted-region check
  belongs to the service's Terraform invocation and the account's SCP.
- **Deletion is not scoped to the run.** `refuse_delete` is all-or-nothing;
  refusing only the destruction of resources the run did not create needs the
  prior state's tags, which the gate does not yet read.
- **Cost estimation is not implemented here.** The gate compares an estimate it
  is given. Producing one is the service's job.
- **Rules are AWS-specific.** The resource type names are AWS provider names;
  another provider needs its own rule set.
