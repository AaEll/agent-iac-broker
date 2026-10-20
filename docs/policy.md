# Policy sets and the cost gate

The rules that decide whether a plan may be applied. Two mechanisms, because
one of them cannot express cost.

- **Rego policy sets**, evaluated by conftest against the plan representation.
  Atlantis runs these as its `policy_check` stage and refuses the apply when
  any set fails.
- **The cost gate**, a custom workflow step, because conftest sees the plan and
  Atlantis has no cost concept.

Both ship in the broker image and are referenced from the Atlantis server's own
repo config. Nothing a caller sends can supply, weaken, or skip a rule.

## The two properties every rule must have

### Deny by default

A rule that cannot establish a change is permitted must refuse it. Three cases
make this concrete, and the third is the one that is easy to get wrong.

**An unlisted type.** The resource-type rule is an allowlist, so a type nobody
considered is refused rather than ignored.

**A missing estimate.** The cost gate exits non-zero when it cannot produce one,
rather than passing the plan through ungated.

**An unknown attribute.** Terraform marks values it cannot resolve until apply
in `change.after_unknown`. A rule that reads `after.instance_type` without
checking whether it is unknown will *silently skip* a plan whose instance type
is computed — admitting exactly the instance the rule exists to refuse. Every
rule judging an attribute must therefore refuse when that attribute is unknown.

The encoding, verified against real OpenTofu 1.13.1 output: a fully unknown
scalar is `true`, and a known map is `{}`.

```rego
# An attribute is unknown when after_unknown marks it true.
unknown(rc, key) if rc.change.after_unknown[key] == true

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_instance"
	mutating(rc)
	unknown(rc, "instance_type")
	msg := sprintf("%s: instance_type is unknown until apply, so the instance family cannot be checked", [rc.address])
}
```

### Every reason is reported

`deny` is a set, so all matching rules contribute. An agent that fixes one
violation should not discover the next a round trip later. Do not write a rule
that short-circuits the set.

## Rule catalog

Each rule names what it refuses. These are the AWS set; another provider needs
its own, since the type names are provider-specific.

| Rule | Refuses |
|---|---|
| `resource_type_not_allowed` | A managed resource type absent from the allowlist |
| `network_control_refused` | VPCs, gateways, route tables, peerings, endpoints. The agent may build inside its plane, not reshape it — refused even when allowlisted |
| `instance_family_not_allowed` | An EC2 instance family outside the allowlist |
| `public_bucket_refused` | A false flag on `aws_s3_bucket_public_access_block`, or a public-read ACL |
| `admin_port_exposed` | Ingress from `0.0.0.0/0` or `::/0` covering an administrative port (22, 3389) |
| `delete_refused` | Any destroy, where the deployment refuses them |
| `attribute_unknown` | An attribute a rule needs that Terraform leaves unknown until apply |
| `attribute_missing` | An attribute a rule needs that is absent |

`network_control_refused` is deliberately unconditional. Listing a route table
in the allowlist does not permit it, because reshaping the plane's own boundary
is a different act from building inside it.

## What is judged

Only managed resources whose real state the plan changes: `mode == "managed"`
and an action in `create`, `update`, or `delete`. A data source read and a
`no-op` change nothing and are not judged.

```rego
mutating(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update", "delete"}
}
```

## Writing rego for conftest 0.71

Use `import rego.v1`. Without it, conftest 0.71 rejects `contains` and `if`
rule heads as conflicting with built-in functions — the failure is a parse
error naming the rule head, which is confusing if the cause is not known.

```rego
package main

import rego.v1

allowed_families := {"t3", "m7i"}
```

The package must be `main` for conftest's default `deny` convention.

## The cost gate

```
agent-iac-cost-gate --plan <planfile.json> --ceiling-usd <n>
  exit 0  → at or under the ceiling
  exit 1  → over the ceiling, or no estimate could be produced
  exit 2  → the step could not run
```

A non-zero exit fails the Atlantis workflow step, which fails the plan, which
blocks the apply. stdout carries one line naming the estimate and the ceiling,
and that line is what reaches the model as the refusal reason — so it states
both figures, since an agent that is told only "too expensive" cannot act.

This is the mechanism that recovers what AWS does not provide. Budgets evaluate
against cost data that lags by hours, so a budget action bounds an overrun
rather than preventing one; pricing the plan before apply turns the ceiling into
a refusal.

### What it does not do

The ceiling is a projected monthly figure for the plan's post-apply state. It
is not a forecast of actual spend: it cannot see usage-driven cost, data
transfer, or anything priced per request. Behind it sit the account's
concurrency quotas, which cap how much can exist at once regardless of what any
estimate said.

## Testing a rule

Every rule proves its negative case. A policy set tested only on compliant
plans is untested, so each rule needs a plan fixture that violates it and an
assertion naming the rule that refuses it.

Fixtures are real `tofu show -json` output, generated from configurations whose
only providers are `null`, `local`, and `random`, so the suite needs no cloud
credential and no spend. That is the same technique the evaluation spike used,
and it is what keeps the tests runnable in CI.

Identifiers in fixtures are obviously invented. No account id, real ARN, client
name, or deployment allowlist belongs in this repository — see
[AGENTS.md](../AGENTS.md).
