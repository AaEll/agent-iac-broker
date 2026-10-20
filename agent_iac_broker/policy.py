"""The deployment's gate policy, and the cost estimate the gate judges with.

Every field is a deployment choice, so none of them carries a permissive
default: an allowlist defaults to empty, which refuses everything, and the cost
ceiling has no default at all. A policy assembled from nothing therefore
refuses rather than admits, which is the behavior a half-configured deployment
should have.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# Ports whose exposure to the whole internet the gate refuses by default.
# Administrative access, not service traffic: a deployment opens 443 through
# its allowlist, but 22 and 3389 are how a host is taken over.
DEFAULT_ADMIN_PORTS: frozenset[int] = frozenset({22, 3389})

# Resource types that reshape the network the agent runs inside. The agent may
# build within its plane; it may not alter the plane's own boundary, so these
# are refused even when a caller lists them as allowed.
NETWORK_CONTROL_TYPES: frozenset[str] = frozenset(
    {
        "aws_vpc",
        "aws_vpc_peering_connection",
        "aws_vpc_peering_connection_accepter",
        "aws_internet_gateway",
        "aws_nat_gateway",
        "aws_egress_only_internet_gateway",
        "aws_route",
        "aws_route_table",
        "aws_route_table_association",
        "aws_main_route_table_association",
        "aws_network_acl",
        "aws_network_acl_rule",
        "aws_ec2_transit_gateway_vpc_attachment",
        "aws_vpc_endpoint",
        "aws_customer_gateway",
        "aws_vpn_connection",
        "aws_vpn_gateway",
    }
)

# CIDRs that mean "the whole internet".
ANY_IPV4 = "0.0.0.0/0"
ANY_IPV6 = "::/0"


@dataclass(frozen=True)
class CostEstimate:
    """A pre-apply cost estimate for one plan.

    Produced by the cost estimator the service runs; the gate only compares it.
    `monthly_usd` is the projected steady-state monthly cost of the plan's
    post-apply state, which is the figure the ceiling is written against.
    """

    monthly_usd: float
    currency: str = "USD"


@dataclass(frozen=True)
class GatePolicy:
    """What this deployment permits a plan to do.

    @param allowed_resource_types: managed resource types a plan may touch.
        Empty refuses every change, which is the unconfigured default.
    @param allowed_instance_families: EC2 instance family prefixes, compared
        against the part of `instance_type` before the dot (`m7i` in
        `m7i.xlarge`). Empty refuses every instance.
    @param monthly_cost_ceiling_usd: the estimate a plan must come in under.
        `None` requires no estimate and performs no cost check.
    @param admin_ports: ports whose exposure to any address is refused.
    @param refuse_delete: whether to refuse plans that destroy anything.
    """

    allowed_resource_types: frozenset[str] = frozenset()
    allowed_instance_families: frozenset[str] = frozenset()
    monthly_cost_ceiling_usd: float | None = None
    admin_ports: frozenset[int] = field(default=DEFAULT_ADMIN_PORTS)
    refuse_delete: bool = False
