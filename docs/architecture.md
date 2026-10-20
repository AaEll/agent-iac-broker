# Architecture

Five systems, two repositories, and one rule about what crosses between them.
The design rationale is the harness repository's
[brokered infrastructure authority](https://github.com/AaEll/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-brokered-infrastructure-authority.md)
note; the decision to adopt rather than build is the
[Atlantis evaluation spike](https://github.com/AaEll/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-atlantis-evaluation-spike.md).
The surfaces are in [contracts.md](contracts.md).

## The shape

```
┌─ control-plane account ─────────────────────────────────────┐
│                                                             │
│  ① harness task (headless)                                  │
│       ctx.iac → the model-facing tool, the privilege check,  │
│       the session log, the outcome record                   │
│                    │ X-Atlantis-Token                        │
│                    ▼                                         │
│  ② Atlantis (adopted)          ③ policy sets + cost gate     │
│       fetch → plan → gate → apply, one operation             │
│       holds the only mutating credential                     │
│                                                             │
└────────────────────┬───────────────────────────┬────────────┘
                     │ SSH: fs, subprocess,      │ applies into
                     │ sandbox effects           │
┌────────────────────▼───────────────────────────▼────────────┐
│  ④ agent-plane account (leased)                             │
│       sandbox host: the agent's shell, read-only AWS        │
│       what Atlantis provisioned on its behalf               │
│       quotas · SCP · reaper · nuke on return                │
└─────────────────────────────────────────────────────────────┘

⑤ Terraform modules stand all of the above up.
```

## The systems

### ① Harness plugins — *harness repository*

Two packages, specified in
[the plugin spec](https://github.com/AaEll/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-20-osf-iac-plugin-spec.md).

`packages/osf/iac` is the Service Definition: `ctx.iac`, the request and
outcome types, and the `SessionEventMap` members that make an apply
reconstructable from the log.

`packages/osf/iac-atlantis` is the provider and the model-facing tool. It owns
the `delegationDepth` refusal, read in-process before any request leaves; the
HTTP call to Atlantis; the refusal-detection rules from
[contracts §1](contracts.md#reading-a-refusal--the-one-contract-detail-that-matters-most);
the outcome record; and the session events.

It holds no AWS credential that can mutate anything. Its authority is the
Atlantis API secret, which buys plan and apply and cannot override a gate.

### ② Atlantis — *adopted, not ours*

The applier. Fetches the commit, plans it, runs the policy sets against the
whole plan, and applies — one operation that trusts no caller. It holds the
only credential in the system able to mutate infrastructure.

We adopted it rather than writing it because it already provides the parts whose
bugs are most expensive: credential holding, plan storage, state locking, the
server-side policy gate, and the refusal to carry an approval forward. The
spike verified each against a running server.

Two configuration facts are load-bearing, not tunable: `--enable-policy-checks`
is the difference between a gate and no gate, and
`--default-tf-distribution=opentofu` keeps the runtime off Terraform's BUSL-1.1.

### ③ Policy sets and the cost gate — *this repository*

The rules. Rego policy sets evaluated by conftest against the plan
representation, plus a cost gate that runs as a custom workflow step because
cost is not expressible to Atlantis's policy stage. Both are specified in
[policy.md](policy.md).

These are server-side: they ship in the broker image and are referenced from
Atlantis's own repo config, never from the repository under change. A caller
cannot supply, weaken, or skip a rule.

### ④ The agent plane — *this repository's modules*

A leased account holding the sandbox host where the agent's shell actually
runs, and whatever Atlantis provisioned on its behalf. The agent's own
credential here is read-only; `packages/ssh/` in the harness is what places
every file and process effect on this side of the line while the harness and
the applier stay on the other.

Behind the gate sit the account's SCP, its concurrency quotas, a TTL reaper on
the run id, and a budget action — layers sized for a gate bypass rather than for
a credentialed agent.

### ⑤ Terraform modules — *this repository*

`osf-control-plane` stands up the harness task, Atlantis, the secrets, and the
outcome table. `osf-agent-plane` leases and configures the agent account.
`osf-plane-link` carries the attachment and the one-port SSH path between them.

Environment-agnostic: every account id, region, CIDR, and image digest is an
input, and networking is injected so a client's networking team keeps route
control.

## What crosses between the repositories

Only the surfaces in [contracts.md](contracts.md): the Atlantis HTTP API, the
cost gate's exit code, the outcome record, and the image digests the modules
take as inputs. No shared files, no generated values, no imports.

That rule is what keeps the harness fork's diff against upstream close to its
own packages, which is the condition for syncing by merge without accumulating
conflict surface.

## Why the privilege asymmetry is not in our code

The original design had the harness enforce the root-versus-subagent split with
an in-process `delegationDepth` check. The spike found something better: the
policy override is not reachable over the API, so **everything on that path is
equally and absolutely bounded** — no caller can override a policy failure.
Override requires a human comment from an owner configured on the Atlantis
server, which no agent holds.

That holds for the surface this design uses, and the surface is wider than it
looks: drift remediation can apply, so it is left disabled. The inventory and
the flags are in [contracts.md](contracts.md#the-rest-of-the-api-surface).

The `delegationDepth` check is still mounted, because it refuses before a
request leaves and keeps the refusal in the session log where it is auditable.
It is defense in depth now rather than the thing that makes the control hold.
