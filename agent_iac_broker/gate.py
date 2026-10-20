"""The gate: decide whether one plan may be applied.

The gate is a pure function of a plan, an optional cost estimate, and a policy.
It launches no process, reads no credential, and reaches no network, so every
refusal in its vocabulary is reachable from a fixture. The service around it
owns fetching the commit, running Terraform, and applying.

Two properties hold throughout, and the tests assert both:

Deny by default. A rule that cannot establish a change is permitted refuses it.
That covers a resource type absent from the allowlist, an attribute Terraform
left unknown until apply, and a required cost estimate that was not supplied.

Every reason is reported. Evaluation does not stop at the first refusal,
because an agent that fixes one violation and resubmits should not discover the
next one a round trip later.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .plan import Plan, ResourceChange
from .policy import (
    ANY_IPV4,
    ANY_IPV6,
    NETWORK_CONTROL_TYPES,
    CostEstimate,
    GatePolicy,
)

# Public-read canned ACLs. Terraform still accepts `acl` on several bucket
# resources, so a plan can make a bucket world-readable without ever touching
# the public-access-block resource.
PUBLIC_ACLS = frozenset({"public-read", "public-read-write", "authenticated-read"})

# The four flags on aws_s3_bucket_public_access_block. Each must be true; any
# false flag leaves a documented route to public objects.
PUBLIC_ACCESS_BLOCK_FLAGS = (
    "block_public_acls",
    "block_public_policy",
    "ignore_public_acls",
    "restrict_public_buckets",
)


@dataclass(frozen=True)
class Refusal:
    """One reason a plan was refused."""

    rule: str
    detail: str
    address: str | None = None

    def __str__(self) -> str:
        where = f"{self.address}: " if self.address else ""
        return f"{where}{self.detail} [{self.rule}]"


@dataclass(frozen=True)
class Verdict:
    """The gate's decision on one plan."""

    allowed: bool
    refusals: tuple[Refusal, ...] = ()
    monthly_usd: float | None = None

    @property
    def summary(self) -> str:
        """A one-line result for a log or a tool response."""
        if self.allowed:
            cost = "" if self.monthly_usd is None else f" (est. ${self.monthly_usd:.2f}/mo)"
            return f"allowed{cost}"
        return f"refused: {'; '.join(str(r) for r in self.refusals)}"


def _port_range(change: ResourceChange) -> tuple[int | None, int | None, bool]:
    """Read a rule's port range, spanning both security-group rule resources.

    @param change: the planned change for a security-group rule resource.
    @returns the inclusive range and whether either bound was unknown. A rule
        carrying no port fields at all reports `(None, None, False)`, which the
        caller reads as every port.
    """
    unknown = False
    bounds: list[int | None] = []
    # aws_security_group_rule uses from_port/to_port; the newer
    # aws_vpc_security_group_ingress_rule uses the same names.
    for key in ("from_port", "to_port"):
        value, is_unknown = change.attribute(key)
        unknown = unknown or is_unknown
        bounds.append(value if isinstance(value, int) else None)
    return bounds[0], bounds[1], unknown


def _covers_admin_port(low: int | None, high: int | None, admin_ports: frozenset[int]) -> bool:
    """Whether a port range includes any administrative port."""
    if low is None and high is None:
        # No bounds means every port, which includes all of them.
        return bool(admin_ports)
    start = low if low is not None else high
    end = high if high is not None else low
    assert start is not None and end is not None
    if start > end:
        start, end = end, start
    return any(start <= port <= end for port in admin_ports)


def _world_open_cidrs(change: ResourceChange) -> tuple[bool, bool]:
    """Whether a rule admits any address, and whether the CIDRs were unknown."""
    unknown = False
    world = False
    for key in ("cidr_blocks", "ipv6_cidr_blocks", "cidr_ipv4", "cidr_ipv6"):
        value, is_unknown = change.attribute(key)
        if is_unknown:
            unknown = True
            continue
        if isinstance(value, str):
            world = world or value in (ANY_IPV4, ANY_IPV6)
        elif isinstance(value, list):
            world = world or any(entry in (ANY_IPV4, ANY_IPV6) for entry in value)
    return world, unknown


def _check_resource_type(change: ResourceChange, policy: GatePolicy) -> list[Refusal]:
    if change.type in NETWORK_CONTROL_TYPES:
        return [
            Refusal(
                rule="network_control_refused",
                detail=(
                    f"{change.type} reshapes the agent plane's own network boundary, "
                    "which the agent may not alter"
                ),
                address=change.address,
            )
        ]
    if change.type not in policy.allowed_resource_types:
        return [
            Refusal(
                rule="resource_type_not_allowed",
                detail=f"{change.type} is not in the allowed resource types",
                address=change.address,
            )
        ]
    return []


def _check_instance_family(change: ResourceChange, policy: GatePolicy) -> list[Refusal]:
    if change.type != "aws_instance" or change.is_delete:
        return []
    instance_type, unknown = change.attribute("instance_type")
    if unknown:
        return [
            Refusal(
                rule="attribute_unknown",
                detail=(
                    "instance_type is unknown until apply, so the instance family cannot be checked"
                ),
                address=change.address,
            )
        ]
    if not isinstance(instance_type, str) or instance_type == "":
        return [
            Refusal(
                rule="attribute_missing",
                detail="instance_type is absent, so the instance family cannot be checked",
                address=change.address,
            )
        ]
    family = instance_type.split(".", 1)[0]
    if family not in policy.allowed_instance_families:
        return [
            Refusal(
                rule="instance_family_not_allowed",
                detail=f"instance family {family} is not allowed ({instance_type})",
                address=change.address,
            )
        ]
    return []


def _check_public_bucket(change: ResourceChange) -> list[Refusal]:
    if change.is_delete:
        return []
    refusals: list[Refusal] = []

    if change.type == "aws_s3_bucket_public_access_block":
        for flag in PUBLIC_ACCESS_BLOCK_FLAGS:
            value, unknown = change.attribute(flag)
            if unknown:
                refusals.append(
                    Refusal(
                        rule="attribute_unknown",
                        detail=(
                            f"{flag} is unknown until apply, so public access cannot be ruled out"
                        ),
                        address=change.address,
                    )
                )
            elif value is False:
                refusals.append(
                    Refusal(
                        rule="public_bucket_refused",
                        detail=f"{flag} is false, which leaves a route to public objects",
                        address=change.address,
                    )
                )

    if change.type in ("aws_s3_bucket_acl", "aws_s3_bucket"):
        acl, unknown = change.attribute("acl")
        if unknown:
            refusals.append(
                Refusal(
                    rule="attribute_unknown",
                    detail="acl is unknown until apply, so public access cannot be ruled out",
                    address=change.address,
                )
            )
        elif isinstance(acl, str) and acl in PUBLIC_ACLS:
            refusals.append(
                Refusal(
                    rule="public_bucket_refused",
                    detail=f"acl {acl} exposes the bucket beyond the account",
                    address=change.address,
                )
            )
    return refusals


def _check_admin_port(change: ResourceChange, policy: GatePolicy) -> list[Refusal]:
    rule_types = (
        "aws_security_group_rule",
        "aws_vpc_security_group_ingress_rule",
    )
    if change.type not in rule_types or change.is_delete:
        return []
    # An egress rule to the world is ordinary; only ingress is judged here.
    direction, _ = change.attribute("type")
    if change.type == "aws_security_group_rule" and direction != "ingress":
        return []

    world, cidr_unknown = _world_open_cidrs(change)
    low, high, port_unknown = _port_range(change)

    if cidr_unknown or port_unknown:
        return [
            Refusal(
                rule="attribute_unknown",
                detail=(
                    "the rule's address range or ports are unknown until apply, so "
                    "exposure of an administrative port cannot be ruled out"
                ),
                address=change.address,
            )
        ]
    if world and _covers_admin_port(low, high, policy.admin_ports):
        ports = sorted(policy.admin_ports)
        return [
            Refusal(
                rule="admin_port_exposed",
                detail=(
                    f"ingress from {ANY_IPV4} covers an administrative port "
                    f"(range {low}-{high}, guarded {ports})"
                ),
                address=change.address,
            )
        ]
    return []


def _check_delete(change: ResourceChange, policy: GatePolicy) -> list[Refusal]:
    if policy.refuse_delete and change.is_delete:
        return [
            Refusal(
                rule="delete_refused",
                detail="this deployment refuses plans that destroy resources",
                address=change.address,
            )
        ]
    return []


def _check_cost(estimate: CostEstimate | None, policy: GatePolicy) -> list[Refusal]:
    ceiling = policy.monthly_cost_ceiling_usd
    if ceiling is None:
        return []
    if estimate is None:
        return [
            Refusal(
                rule="cost_estimate_missing",
                detail=f"no cost estimate was supplied, and a ${ceiling:.2f}/mo ceiling applies",
            )
        ]
    if estimate.currency != "USD":
        return [
            Refusal(
                rule="cost_currency_unsupported",
                detail=f"estimate is in {estimate.currency}; the ceiling is written in USD",
            )
        ]
    if estimate.monthly_usd > ceiling:
        return [
            Refusal(
                rule="cost_ceiling_exceeded",
                detail=(
                    f"estimate ${estimate.monthly_usd:.2f}/mo exceeds the ${ceiling:.2f}/mo ceiling"
                ),
            )
        ]
    return []


def evaluate(
    plan: Plan,
    policy: GatePolicy,
    estimate: CostEstimate | None = None,
) -> Verdict:
    """Decide whether this plan may be applied.

    @param plan: the parsed `terraform show -json` representation.
    @param policy: what this deployment permits.
    @param estimate: the pre-apply cost estimate, when one was produced.
    @returns the verdict, carrying every refusal rather than only the first.
    """
    refusals: list[Refusal] = []

    for change in plan.mutating_changes:
        refusals.extend(_check_resource_type(change, policy))
        refusals.extend(_check_instance_family(change, policy))
        refusals.extend(_check_public_bucket(change))
        refusals.extend(_check_admin_port(change, policy))
        refusals.extend(_check_delete(change, policy))

    refusals.extend(_check_cost(estimate, policy))

    return Verdict(
        allowed=not refusals,
        refusals=tuple(refusals),
        monthly_usd=None if estimate is None else estimate.monthly_usd,
    )


def evaluate_document(
    document: Any,
    policy: GatePolicy,
    estimate: CostEstimate | None = None,
) -> Verdict:
    """Parse a plan document and evaluate it.

    @param document: the decoded `terraform show -json` output.
    @param policy: what this deployment permits.
    @param estimate: the pre-apply cost estimate, when one was produced.
    @returns the verdict.
    @raises PlanParseError: when the document is not a plan representation. The
        caller turns that into a refusal; the gate does not guess at a plan it
        cannot read.
    """
    from .plan import parse_plan

    return evaluate(parse_plan(document), policy, estimate)
