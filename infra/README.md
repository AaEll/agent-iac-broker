# Deploying

Two Terraform modules, a container image, and one trial root that puts the
smallest useful version of this in a real account.

- [`docker/`](docker) — the broker image: Atlantis plus the rule sets, conftest, OpenTofu, and the cost gate
- [`terraform/modules/control-plane`](terraform/modules/control-plane) — the applier, the agent task, state, secrets, the outcome table, three IAM roles
- [`terraform/modules/agent-plane`](terraform/modules/agent-plane) — the apply role and the denials bounding it, a read-only role, the budget, the reaper
- [`terraform/examples/mvp-single-account`](terraform/examples/mvp-single-account) — the trial

## The trial, and what it proves

One account, one question: **does the gate refuse and admit, for real, in real
AWS?**

It proves exactly that. A compliant plan applies, a violating plan is refused,
and the refusal names the rule. Nothing more should be read into it.

What it gives up is the authority boundary. A Service Control Policy, a budget,
and a quota all attach to an account, so one account cannot bound itself. The
trial collapses both planes into one, which is fine for answering the question
and is not a client deployment. The inputs have the same shape as the
two-account form, so splitting later changes inputs rather than code.

The fixture repository it acts on uses only the `null`, `local`, and `random`
providers, so the infrastructure under change costs nothing. The only spend is
the Atlantis task and its storage.

## Order of operations

The two modules construct each other's role ARNs from an account id and the
shared `name_prefix` rather than passing outputs, so **either can be applied
first**. An earlier version took the other's output in both directions and
neither could be applied at all.

Both must be called with the same `name_prefix`, because that is what makes the
constructed ARNs line up.

### 1. Publish the image

CI builds it and prints the digest to pin:

```sh
gh workflow run image.yml --repo eFactory-ai/agent-iac-broker
gh run watch --repo eFactory-ai/agent-iac-broker
```

The modules **refuse a tag**: a refused apply is signalled by an internal
Atlantis message rather than a stable error code, so a version moving under the
deployment could turn a refusal into a success with no configuration changing.
Pin `repository@sha256:...`.

### 2. Put the two secrets in place

```sh
aws secretsmanager create-secret --name osf-mvp-git-token \
  --secret-string "$GIT_TOKEN"
aws secretsmanager create-secret --name osf-mvp-model-key \
  --secret-string "$MODEL_API_KEY"
```

The git token needs only enough to clone the fixture repository and comment on
it. The model key is unused by the trial — the gate is driven directly over the
API — but the module requires it, because the agent task definition it also
creates would be broken without it.

The `X-Atlantis-Token` is **not** created here. The module generates it, so it
never passes through a tfvars file or a shell history.

### 3. Apply

```sh
cd terraform/examples/mvp-single-account
tofu init
tofu apply \
  -var "broker_image=ghcr.io/efactory-ai/agent-iac-broker/broker@sha256:…" \
  -var "agent_image=ghcr.io/efactory-ai/agent-iac-broker/broker@sha256:…" \
  -var 'repo_allowlist=["github.com/eFactory-ai/osf-iac-trial"]' \
  -var "git_user=…" \
  -var "git_token_secret_arn=…" \
  -var "model_api_key_secret_arn=…"
```

`agent_image` can be the broker digest for the trial. Nothing runs it.

### 4. Drive the gate from inside the VPC

Atlantis has no public ingress, and its security group admits port 4141 only
from the task security group itself. So the two requests are made from a
one-off task in that group rather than from a laptop:

```sh
TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id "$(tofu output -raw atlantis_api_secret_arn)" \
  --query SecretString --output text)

# A compliant ref: expect the plan to pass policy and the apply to succeed.
# A violating ref: expect "Some policy sets did not pass." and a refused apply.
```

Read the result from the **per-project** `Failure` field. A refusal arrives with
a null top-level `Error` and an empty top-level `Failure`, so anything checking
the HTTP status or the top level reads a refused apply as a success. The
contract and the recorded responses are in
[docs/contracts.md](../docs/contracts.md).

## What the trial costs

Small, and the shape matters more than the number. The task runs continuously
once applied, so the bill is time-based rather than per-request:

| Item | Driver |
|---|---|
| Fargate task | 1 vCPU / 2 GB, continuous while the service is up |
| NAT gateway | Hourly, plus data. The largest line item by far |
| EFS | A few MB of Atlantis state |
| Secrets Manager | Three secrets |
| S3, DynamoDB | Negligible at trial volume |

Destroy it when the question is answered:

```sh
tofu destroy
```

The state bucket sets `force_destroy = false`, so a bucket holding objects
survives `destroy` deliberately — state is the one thing that should not be
easy to delete by accident. Empty it explicitly if you mean to.

## Not in this code yet

Stated so none of it reads as an oversight.

- **The plane link and the sandbox host.** The agent's tools are meant to run
  on a host in the agent plane over SSH. Neither exists here, so the agent task
  would run its tools in the control plane.
- **The SCP and the concurrency quotas.** Both attach at the organization level
  and need credentials these modules do not take. The budget and the reaper are
  here; the hard proactive ceilings are not.
- **The reaper's target.** The schedule rule exists and invokes nothing, so the
  lease TTL is not yet enforced.
- **The cost estimator.** The gate judges an estimate and refuses when none is
  present, which is the safe direction, but nothing produces one yet. So
  `monthly_cost_ceiling_usd` is `null` by default and the cost step is omitted
  from the workflow entirely: setting a ceiling without an estimator refuses
  every plan on cost, and the trial could never demonstrate an apply. The
  omission is visible in the composed workflow rather than silent.
