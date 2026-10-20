# API contracts

The surfaces that join the systems, and nothing else. A change to any of them
is a change to a published contract: version it rather than reshaping a live
one.

Every shape below was observed from a running Atlantis 0.48.1 during the
[evaluation spike](https://github.com/AaEll/OpenSoftwareFactory/blob/main/.agents/notes/proposed/architecture/2026-10-19-atlantis-evaluation-spike.md),
not transcribed from documentation. Where a field is undocumented upstream but
load-bearing for us, that is called out.

## Contents

- [1. Harness → Atlantis](#1-harness--atlantis) — plan and apply
- [2. Policy input](#2-policy-input) — what rego sees
- [3. Cost gate step](#3-cost-gate-step) — the exit-code contract
- [4. Outcome record](#4-outcome-record) — where the harness reads the verdict
- [5. Session events](#5-session-events) — the harness's own log
- [6. Deployment inputs](#6-deployment-inputs) — image tags and policy config

-----

## 1. Harness → Atlantis

Two endpoints. Authentication is the `X-Atlantis-Token` header matching the
server's `--api-secret`; there is no per-request identity, so the token is the
whole access rule and must be held only by the harness task role.

### Request

Identical for both `POST /api/plan` and `POST /api/apply`:

```json
{
  "repository": "<owner>/<repo>",
  "ref": "<branch or commit ref>",
  "type": "Github",
  "paths": [{ "directory": ".", "workspace": "default" }]
}
```

| Field | Required | Meaning |
|---|---|---|
| `repository` | yes | `owner/name`, and must match the server's `--repo-allowlist` |
| `ref` | yes | Branch name or ref. For a non-branch ref, also send `base_branch` |
| `type` | yes | `Github` or `Gitlab` |
| `paths` | one of | `[{directory, workspace}]`; `workspace` is `"default"` when unused |
| `projects` | one of | Named projects instead of `paths`. At least one of the two is required |
| `PR` | no | Omit it. Omitted or `0` runs an isolated synthetic non-PR workflow, which is the mode this design uses |

### Response

```json
{
  "Error": null,
  "Failure": "",
  "PlansDeleted": false,
  "ProjectResults": [
    {
      "Command": 1,
      "RepoRelDir": ".",
      "Workspace": "default",
      "Failure": "",
      "Error": null,
      "PlanSuccess": { "TerraformOutput": "…" },
      "PolicyCheckResults": null,
      "ApplySuccess": ""
    }
  ]
}
```

`Command` is an integer, and the values we rely on were read from live
responses rather than documentation:

| Value | Stage |
|---|---|
| `0` | apply |
| `1` | plan |
| `3` | policy_check |

A `/api/plan` call with policy checks enabled returns **two** project results
for one project: the plan (`Command: 1`) and the policy check (`Command: 3`).

### Reading a refusal — the one contract detail that matters most

**A refusal arrives with `Error: null` and top-level `Failure: ""`.** The
refusal appears only in the *per-project* `Failure` string. A client that
checks the HTTP status, the top-level `Error`, or the top-level `Failure` reads
a refused apply as a success.

The client MUST therefore treat the request as refused when any project result
carries a non-empty `Failure` or a non-null `Error`, and treat an empty
`ProjectResults` as a failure rather than as nothing-to-do.

The two refusal strings this design depends on, verbatim:

| String | Stage | Means |
|---|---|---|
| `Some policy sets did not pass.` | policy_check | The gate refused this plan |
| `All policies must pass for project before running apply.` | apply | The apply was blocked by the gate |

These are **matched as strings**, which is brittle: they are Atlantis's internal
messages, not a stable error code. The client pins the Atlantis image by digest
and a contract test asserts both strings against the pinned version, so an
upstream rewording fails CI rather than silently turning a refusal into a
success.

### Policy check result

Present on the `Command: 3` result whether or not the policy passed:

```json
{
  "PolicyCheckResults": {
    "PolicySetResults": [
      {
        "PolicySetName": "instance-family",
        "PolicyOutput": "FAIL - … - main - null_resource.stand_in: instance family \"x8g\" is not allowed (x8g.48xlarge)\n\n1 test, 0 passed, 0 warnings, 1 failure, 0 exceptions\n",
        "Passed": false,
        "ReqApprovalCount": 1,
        "Approvals": null,
        "Hashes": ["ce688eaf…"],
        "PolicyItemRegex": "(?s).+"
      }
    ],
    "ApprovePoliciesCmd": "atlantis approve_policies -d .",
    "RePlanCmd": "atlantis plan -d .",
    "ApplyCmd": "atlantis apply -d .",
    "LockURL": "…",
    "HasDiverged": false
  }
}
```

`Passed` is the field to branch on. `PolicyOutput` is conftest's human-readable
text, which is what reaches the model as the reason for a refusal; it is not
structured, so the model gets prose rather than a parsed rule list.

`ApprovePoliciesCmd` names a command that **is not reachable over this API**:
`/api/approve_policies` is not a registered route. Overriding a policy failure
requires a human comment from an owner configured server-side. That is the
property the privilege asymmetry rests on, so nothing may expose it to a
caller.

### What the client must not assume

- **An apply is not bound to an earlier plan.** `/api/apply` re-plans at the
  current ref and gates again, applying a planfile it creates during the apply
  request. There is no plan handle to carry between calls. The invariant is
  that nothing is applied which has not just passed the gate — not that the
  plan a caller was shown is the plan applied.
- **`PlansDeleted` is not an error signal.** It was `false` on every observed
  response, including refusals.
- **No session identity crosses this boundary.** There is no field for it, so
  session-scoped state lives in the [outcome record](#4-outcome-record).

-----

## 2. Policy input

Atlantis runs `conftest test` against the plan representation
(`tofu show -json`), so the rego `input` is the plan document: `input.format_version`,
`input.terraform_version`, and `input.resource_changes[]` with each entry's
`address`, `mode`, `type`, `name`, and `change.{actions,before,after,after_unknown}`.

Two properties of that document the rules depend on:

**`after_unknown` marks values Terraform cannot resolve until apply.** A fully
unknown scalar is `true`; a known map is `{}`. A rule that reads an attribute
without checking `after_unknown` will silently skip the change it exists to
refuse, so every rule judging an attribute must refuse when that attribute is
unknown. See [policy.md](policy.md).

**Policies are server-side.** They come from the Atlantis server's repo config,
never from the repository under change, so a caller cannot supply or weaken a
rule.

-----

## 3. Cost gate step

Cost is not expressible to Atlantis's policy stage — `conftest` sees the plan,
and Atlantis has no cost concept — so the ceiling is enforced as a custom
workflow step rather than as rego.

The contract is an exit code:

```
agent-iac-cost-gate --plan <planfile.json> --ceiling-usd <n>
  exit 0  → at or under the ceiling
  exit 1  → over the ceiling, or no estimate could be produced
  exit 2  → the step could not run (misconfiguration)
```

A non-zero exit fails the Atlantis workflow step, which fails the plan, which
blocks the apply. **Deny by default applies here too**: an estimate that cannot
be produced exits non-zero rather than passing the plan through ungated.

stdout carries one line naming the estimate and the ceiling, which is what
reaches the model as the refusal reason.

-----

## 4. Outcome record

Atlantis keeps no session-scoped state, so the harness's own record of an apply
lives in DynamoDB, written by the harness client and read by nothing else.

| Attribute | Type | Meaning |
|---|---|---|
| `pk` | string | `<sessionId>#<commit>` — the idempotency key |
| `sessionId` | string | The harness session that requested it |
| `commit` | string | The full commit SHA the request named |
| `outcome` | string | `applied` · `refused` · `failed` |
| `reason` | string | For a refusal, the `PolicyOutput` or cost line |
| `startedAt` | number | Epoch milliseconds |
| `settledAt` | number | Epoch milliseconds, absent while in flight |
| `ttl` | number | Epoch seconds; the record expires with the run's retention |

**Idempotency.** The client writes the record with a condition that the key does
not already exist. A retried supervisor task therefore reads the first outcome
instead of issuing a second apply. Since Atlantis re-plans on every apply, a
duplicate request without this guard would be a second real apply, not a
no-op.

-----

## 5. Session events

The harness owns these; they are what makes an apply reconstructable from the
session log, and the model-visible-implies-logged rule requires them because
the model sees the verdict.

| Event | Payload |
|---|---|
| `iac/apply-requested` | `{ commit, repository, directory, workspace }` |
| `iac/apply-decided` | `{ commit, outcome, reason?, estimateUsd? }` |
| `iac/apply-settled` | `{ commit, outcome, summary }` |

Adding these members to `SessionEventMap` changes both SDK projections, so the
TypeScript and Python SDK expected outputs update in the same change. `pnpm run
test` covers neither.

-----

## 6. Deployment inputs

What the Terraform modules take, and what must not drift:

| Input | Why it is a contract |
|---|---|
| `atlantis_image` | Pinned **by digest**, not a tag. The refusal strings in §1 are version-coupled |
| `broker_image` | The image carrying the cost gate step and the policy sets |
| `policy_sets` | Paths inside the image, referenced by the server-side repo config |
| `api_secret_arn` | Secrets Manager ARN. The value is the entire access rule for §1 |
| `outcome_table_name` | The DynamoDB table in §4 |

Two Atlantis flags are deployment invariants rather than tuning options, and the
module sets both unconditionally:

- **`--enable-policy-checks`.** Without it the policy stage does not run at
  all, and a violating plan applies cleanly. This was observed: the spike's
  first run omitted the flag and applied a plan the policy refuses.
- **`--default-tf-distribution=opentofu`.** Keeps the runtime on MPL-2.0 rather
  than Terraform's BUSL-1.1, whose Additional Use Grant is a live question for
  a product that embeds it.

`--write-git-creds` mutates global git configuration — on a developer machine it
added an `insteadOf` rewrite of ssh GitHub URLs for the whole account. It is
acceptable only because Atlantis runs in a container whose home directory is
its own.
