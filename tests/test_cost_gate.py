"""The cost gate's exit codes, which are its contract.

The refusals matter more than the pass: a gate that admits a plan when it
cannot tell what the plan costs is worse than no gate, because the deployment
believes it has a ceiling.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_iac_broker.cost_gate import (
    EXIT_ALLOWED,
    EXIT_REFUSED,
    EXIT_UNUSABLE,
    Estimate,
    EstimateError,
    decide,
    parse_estimate,
    run,
)


def write(tmp_path: Path, name: str, document: object) -> Path:
    p = tmp_path / name
    p.write_text(json.dumps(document))
    return p


class TestDenyByDefault:
    def test_a_missing_estimate_is_refused(self, tmp_path: Path) -> None:
        assert (
            run(["--estimate", str(tmp_path / "absent.json"), "--ceiling-usd", "500"])
            == EXIT_REFUSED
        )

    def test_unreadable_json_is_refused(self, tmp_path: Path) -> None:
        p = tmp_path / "broken.json"
        p.write_text("{not json")
        assert run(["--estimate", str(p), "--ceiling-usd", "500"]) == EXIT_REFUSED

    def test_an_estimate_without_a_total_is_refused(self, tmp_path: Path) -> None:
        p = write(tmp_path, "e.json", {"currency": "USD"})
        assert run(["--estimate", str(p), "--ceiling-usd", "500"]) == EXIT_REFUSED

    @pytest.mark.parametrize("bad", ["abc", None, [], {}])
    def test_a_non_numeric_total_is_refused(self, bad: object) -> None:
        with pytest.raises(EstimateError):
            parse_estimate({"totalMonthlyCost": bad})

    def test_a_negative_total_is_refused(self) -> None:
        # A negative total would pass every ceiling.
        with pytest.raises(EstimateError):
            parse_estimate({"totalMonthlyCost": -1})

    def test_a_non_finite_total_is_refused(self) -> None:
        with pytest.raises(EstimateError):
            parse_estimate({"totalMonthlyCost": float("inf")})


class TestDecision:
    def test_under_the_ceiling_is_allowed(self) -> None:
        code, line = decide(Estimate(120.0, "USD"), 500.0)
        assert code == EXIT_ALLOWED
        assert "120.00" in line and "500.00" in line

    def test_exactly_at_the_ceiling_is_allowed(self) -> None:
        assert decide(Estimate(500.0, "USD"), 500.0)[0] == EXIT_ALLOWED

    def test_over_the_ceiling_is_refused_and_names_both_figures(self) -> None:
        code, line = decide(Estimate(9000.0, "USD"), 500.0)
        assert code == EXIT_REFUSED
        assert "9000.00" in line and "500.00" in line

    def test_another_currency_is_refused(self) -> None:
        code, line = decide(Estimate(10.0, "EUR"), 500.0)
        assert code == EXIT_REFUSED
        assert "EUR" in line


class TestEstimateShapes:
    def test_infracost_shape(self) -> None:
        assert (
            parse_estimate({"totalMonthlyCost": "120.50", "currency": "USD"}).monthly_usd == 120.5
        )

    def test_plain_shape(self) -> None:
        assert parse_estimate({"monthly_usd": 42}).monthly_usd == 42.0

    def test_currency_defaults_to_usd(self) -> None:
        assert parse_estimate({"monthly_usd": 1}).currency == "USD"

    def test_a_non_object_document_is_refused(self) -> None:
        with pytest.raises(EstimateError):
            parse_estimate([])


class TestMisconfiguration:
    def test_a_negative_ceiling_is_unusable_not_refused(self, tmp_path: Path) -> None:
        # Distinguishable from a refusal: this is a deployment to fix, not a
        # plan to change.
        p = write(tmp_path, "e.json", {"monthly_usd": 1})
        assert run(["--estimate", str(p), "--ceiling-usd", "-5"]) == EXIT_UNUSABLE


class TestPlanContext:
    def test_a_malformed_plan_does_not_change_the_verdict(self, tmp_path: Path) -> None:
        est = write(tmp_path, "e.json", {"monthly_usd": 1})
        plan = tmp_path / "plan.json"
        plan.write_text("{not json")
        assert (
            run(
                [
                    "--estimate",
                    str(est),
                    "--ceiling-usd",
                    "500",
                    "--plan",
                    str(plan),
                ]
            )
            == EXIT_ALLOWED
        )

    def test_the_plan_is_only_context(self, tmp_path: Path) -> None:
        est = write(tmp_path, "e.json", {"monthly_usd": 9000})
        plan = write(tmp_path, "plan.json", {"resource_changes": [{"address": "a"}]})
        assert (
            run(
                [
                    "--estimate",
                    str(est),
                    "--ceiling-usd",
                    "500",
                    "--plan",
                    str(plan),
                ]
            )
            == EXIT_REFUSED
        )
