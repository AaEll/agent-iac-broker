"""The gate's decisions, stated as the refusals it must produce.

Each test names a change a deployment would want refused and asserts the rule
that refuses it. The deny-by-default tests matter most: they cover the cases
where the gate cannot establish that a change is safe — an unlisted resource
type, an attribute Terraform leaves unknown until apply, a missing cost
estimate — because those are the paths where a permissive bug would admit
exactly what the gate exists to stop.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from agent_iac_broker import (
    CostEstimate,
    GatePolicy,
    PlanParseError,
    evaluate,
    evaluate_document,
    parse_plan,
)

FIXTURES = Path(__file__).parent / "fixtures"


def fixture(name: str) -> Any:
    """Load one `terraform show -json` fixture."""
    return json.loads((FIXTURES / f"{name}.json").read_text())


def change(
    address: str,
    resource_type: str,
    *,
    actions: list[str] | None = None,
    after: dict[str, Any] | None = None,
    after_unknown: dict[str, Any] | None = None,
    mode: str = "managed",
) -> dict[str, Any]:
    """Build one resource_changes entry."""
    return {
        "address": address,
        "mode": mode,
        "type": resource_type,
        "name": address.split(".")[-1],
        "change": {
            "actions": actions or ["create"],
            "before": None,
            "after": after or {},
            "after_unknown": after_unknown or {},
        },
    }


def plan_of(*changes: dict[str, Any]) -> dict[str, Any]:
    """Build a plan document around the given changes."""
    return {
        "format_version": "1.2",
        "terraform_version": "1.9.8",
        "resource_changes": list(changes),
    }


# A policy permissive enough that each test's own violation is the only one.
PERMISSIVE = GatePolicy(
    allowed_resource_types=frozenset(
        {
            "aws_instance",
            "aws_s3_bucket",
            "aws_s3_bucket_acl",
            "aws_s3_bucket_public_access_block",
            "aws_security_group",
            "aws_security_group_rule",
            "aws_vpc_security_group_ingress_rule",
            "aws_db_instance",
        }
    ),
    allowed_instance_families=frozenset({"t3", "m7i"}),
)


def rules(verdict: Any) -> set[str]:
    """The rule names a verdict refused on."""
    return {r.rule for r in verdict.refusals}


class TestAllowed:
    def test_a_compliant_plan_is_allowed(self) -> None:
        verdict = evaluate_document(fixture("plan_compliant"), PERMISSIVE)
        assert verdict.allowed, verdict.summary
        assert verdict.refusals == ()

    def test_an_empty_plan_is_allowed(self) -> None:
        assert evaluate_document(plan_of(), PERMISSIVE).allowed

    def test_a_data_source_is_not_judged(self) -> None:
        # Reading a disallowed type mutates nothing.
        document = plan_of(change("data.aws_ami.x", "aws_ami", mode="data", actions=["read"]))
        assert evaluate_document(document, PERMISSIVE).allowed

    def test_a_no_op_is_not_judged(self) -> None:
        document = plan_of(change("aws_kms_key.k", "aws_kms_key", actions=["no-op"]))
        assert evaluate_document(document, PERMISSIVE).allowed

    def test_egress_to_the_world_is_ordinary(self) -> None:
        document = plan_of(
            change(
                "aws_security_group_rule.out",
                "aws_security_group_rule",
                after={
                    "type": "egress",
                    "from_port": 0,
                    "to_port": 0,
                    "cidr_blocks": ["0.0.0.0/0"],
                },
            )
        )
        assert evaluate_document(document, PERMISSIVE).allowed


class TestDenyByDefault:
    def test_an_unlisted_resource_type_is_refused(self) -> None:
        verdict = evaluate_document(fixture("plan_unlisted_type"), PERMISSIVE)
        assert not verdict.allowed
        assert "resource_type_not_allowed" in rules(verdict)

    def test_an_empty_allowlist_refuses_everything(self) -> None:
        document = plan_of(
            change("aws_instance.web", "aws_instance", after={"instance_type": "t3.micro"})
        )
        verdict = evaluate_document(document, GatePolicy())
        assert not verdict.allowed
        assert "resource_type_not_allowed" in rules(verdict)

    def test_an_unknown_instance_type_is_refused(self) -> None:
        verdict = evaluate_document(fixture("plan_unknown_instance_type"), PERMISSIVE)
        assert not verdict.allowed
        assert "attribute_unknown" in rules(verdict)

    def test_an_absent_instance_type_is_refused(self) -> None:
        document = plan_of(change("aws_instance.web", "aws_instance", after={}))
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "attribute_missing" in rules(verdict)

    def test_unknown_cidrs_refuse_the_rule(self) -> None:
        document = plan_of(
            change(
                "aws_security_group_rule.ssh",
                "aws_security_group_rule",
                after={"type": "ingress", "from_port": 22, "to_port": 22},
                after_unknown={"cidr_blocks": True},
            )
        )
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "attribute_unknown" in rules(verdict)

    def test_unknown_public_access_flags_are_refused(self) -> None:
        document = plan_of(
            change(
                "aws_s3_bucket_public_access_block.b",
                "aws_s3_bucket_public_access_block",
                after={
                    "block_public_acls": True,
                    "block_public_policy": True,
                    "ignore_public_acls": True,
                },
                after_unknown={"restrict_public_buckets": True},
            )
        )
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "attribute_unknown" in rules(verdict)


class TestPolicyRefusals:
    def test_a_public_bucket_is_refused(self) -> None:
        verdict = evaluate_document(fixture("plan_public_bucket"), PERMISSIVE)
        assert not verdict.allowed
        assert "public_bucket_refused" in rules(verdict)

    def test_a_public_acl_is_refused(self) -> None:
        document = plan_of(
            change("aws_s3_bucket_acl.b", "aws_s3_bucket_acl", after={"acl": "public-read"})
        )
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "public_bucket_refused" in rules(verdict)

    def test_ssh_open_to_the_world_is_refused(self) -> None:
        verdict = evaluate_document(fixture("plan_ssh_open"), PERMISSIVE)
        assert not verdict.allowed
        assert "admin_port_exposed" in rules(verdict)

    def test_a_wide_range_covering_ssh_is_refused(self) -> None:
        document = plan_of(
            change(
                "aws_security_group_rule.wide",
                "aws_security_group_rule",
                after={
                    "type": "ingress",
                    "from_port": 1,
                    "to_port": 1024,
                    "cidr_blocks": ["0.0.0.0/0"],
                },
            )
        )
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "admin_port_exposed" in rules(verdict)

    def test_an_absent_port_range_means_every_port(self) -> None:
        document = plan_of(
            change(
                "aws_vpc_security_group_ingress_rule.all",
                "aws_vpc_security_group_ingress_rule",
                after={"cidr_ipv4": "0.0.0.0/0"},
            )
        )
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "admin_port_exposed" in rules(verdict)

    def test_ipv6_any_is_refused(self) -> None:
        document = plan_of(
            change(
                "aws_vpc_security_group_ingress_rule.v6",
                "aws_vpc_security_group_ingress_rule",
                after={"cidr_ipv6": "::/0", "from_port": 22, "to_port": 22},
            )
        )
        verdict = evaluate_document(document, PERMISSIVE)
        assert not verdict.allowed
        assert "admin_port_exposed" in rules(verdict)

    def test_ssh_from_one_network_is_allowed(self) -> None:
        document = plan_of(
            change(
                "aws_security_group_rule.ssh",
                "aws_security_group_rule",
                after={
                    "type": "ingress",
                    "from_port": 22,
                    "to_port": 22,
                    "cidr_blocks": ["10.0.0.0/8"],
                },
            )
        )
        assert evaluate_document(document, PERMISSIVE).allowed

    def test_a_disallowed_instance_family_is_refused(self) -> None:
        verdict = evaluate_document(fixture("plan_disallowed_instance"), PERMISSIVE)
        assert not verdict.allowed
        assert "instance_family_not_allowed" in rules(verdict)

    def test_network_control_is_refused_even_when_allowlisted(self) -> None:
        # The agent may not reshape its own plane, so listing the type does not help.
        permits_vpc = GatePolicy(
            allowed_resource_types=frozenset({"aws_route_table"}),
            allowed_instance_families=frozenset({"t3"}),
        )
        document = plan_of(change("aws_route_table.r", "aws_route_table"))
        verdict = evaluate_document(document, permits_vpc)
        assert not verdict.allowed
        assert rules(verdict) == {"network_control_refused"}

    def test_delete_is_refused_when_the_deployment_says_so(self) -> None:
        document = plan_of(change("aws_s3_bucket.b", "aws_s3_bucket", actions=["delete"]))
        strict = GatePolicy(
            allowed_resource_types=frozenset({"aws_s3_bucket"}),
            refuse_delete=True,
        )
        verdict = evaluate_document(document, strict)
        assert not verdict.allowed
        assert "delete_refused" in rules(verdict)

    def test_delete_is_permitted_by_default(self) -> None:
        document = plan_of(change("aws_s3_bucket.b", "aws_s3_bucket", actions=["delete"]))
        permits = GatePolicy(allowed_resource_types=frozenset({"aws_s3_bucket"}))
        assert evaluate_document(document, permits).allowed


class TestCost:
    POLICY = GatePolicy(
        allowed_resource_types=frozenset({"aws_instance"}),
        allowed_instance_families=frozenset({"m7i"}),
        monthly_cost_ceiling_usd=500.0,
    )

    def test_an_estimate_over_the_ceiling_is_refused(self) -> None:
        document = plan_of(
            change("aws_instance.web", "aws_instance", after={"instance_type": "m7i.xlarge"})
        )
        verdict = evaluate_document(document, self.POLICY, CostEstimate(monthly_usd=1200.0))
        assert not verdict.allowed
        assert "cost_ceiling_exceeded" in rules(verdict)
        # The refusal names both figures, so the agent can act on it.
        detail = next(r.detail for r in verdict.refusals if r.rule == "cost_ceiling_exceeded")
        assert "1200.00" in detail and "500.00" in detail

    def test_a_missing_estimate_is_refused_when_a_ceiling_applies(self) -> None:
        document = plan_of(
            change("aws_instance.web", "aws_instance", after={"instance_type": "m7i.large"})
        )
        verdict = evaluate_document(document, self.POLICY, None)
        assert not verdict.allowed
        assert "cost_estimate_missing" in rules(verdict)

    def test_an_estimate_under_the_ceiling_is_allowed(self) -> None:
        document = plan_of(
            change("aws_instance.web", "aws_instance", after={"instance_type": "m7i.large"})
        )
        verdict = evaluate_document(document, self.POLICY, CostEstimate(monthly_usd=120.0))
        assert verdict.allowed, verdict.summary
        assert verdict.monthly_usd == 120.0

    def test_an_estimate_in_another_currency_is_refused(self) -> None:
        document = plan_of(
            change("aws_instance.web", "aws_instance", after={"instance_type": "m7i.large"})
        )
        verdict = evaluate_document(
            document, self.POLICY, CostEstimate(monthly_usd=10.0, currency="EUR")
        )
        assert not verdict.allowed
        assert "cost_currency_unsupported" in rules(verdict)

    def test_no_ceiling_means_no_cost_check(self) -> None:
        document = plan_of(
            change("aws_instance.web", "aws_instance", after={"instance_type": "m7i.large"})
        )
        policy = GatePolicy(
            allowed_resource_types=frozenset({"aws_instance"}),
            allowed_instance_families=frozenset({"m7i"}),
        )
        assert evaluate_document(document, policy, None).allowed


class TestReporting:
    def test_every_refusal_is_reported_not_only_the_first(self) -> None:
        verdict = evaluate_document(fixture("plan_many_violations"), PERMISSIVE)
        assert not verdict.allowed
        # A public bucket, exposed SSH, and a disallowed family in one plan.
        assert {
            "public_bucket_refused",
            "admin_port_exposed",
            "instance_family_not_allowed",
        } <= rules(verdict)

    def test_a_refusal_names_the_resource(self) -> None:
        verdict = evaluate_document(fixture("plan_ssh_open"), PERMISSIVE)
        refusal = next(r for r in verdict.refusals if r.rule == "admin_port_exposed")
        assert refusal.address == "aws_security_group_rule.ssh_world"
        assert refusal.address in str(refusal)

    def test_the_summary_states_the_outcome(self) -> None:
        allowed = evaluate_document(
            fixture("plan_compliant"), PERMISSIVE, CostEstimate(monthly_usd=42.5)
        )
        assert allowed.summary == "allowed (est. $42.50/mo)"
        refused = evaluate_document(fixture("plan_ssh_open"), PERMISSIVE)
        assert refused.summary.startswith("refused: ")


class TestPlanParsing:
    def test_a_non_object_document_is_rejected(self) -> None:
        with pytest.raises(PlanParseError):
            parse_plan([])

    def test_a_non_list_resource_changes_is_rejected(self) -> None:
        with pytest.raises(PlanParseError):
            parse_plan({"resource_changes": {}})

    def test_a_change_without_an_address_is_rejected(self) -> None:
        with pytest.raises(PlanParseError):
            parse_plan({"resource_changes": [{"type": "aws_s3_bucket", "change": {}}]})

    def test_a_change_without_a_type_is_rejected(self) -> None:
        with pytest.raises(PlanParseError):
            parse_plan({"resource_changes": [{"address": "x", "change": {}}]})

    def test_a_plan_with_no_changes_key_is_empty(self) -> None:
        assert parse_plan({"format_version": "1.2"}).resource_changes == ()

    def test_unknown_top_level_keys_are_ignored(self) -> None:
        # A newer format_version must not break the gate.
        plan = parse_plan({"format_version": "9.9", "something_new": {"a": 1}})
        assert plan.format_version == "9.9"

    def test_the_parsed_plan_is_what_evaluate_judges(self) -> None:
        document = fixture("plan_ssh_open")
        assert evaluate(parse_plan(document), PERMISSIVE).refusals == (
            evaluate_document(document, PERMISSIVE).refusals
        )
