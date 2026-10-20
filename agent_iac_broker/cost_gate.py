"""The cost gate, run as an Atlantis workflow step.

Cost is not expressible to Atlantis's policy stage — conftest sees the plan and
Atlantis has no cost concept — so the ceiling is enforced here instead. A
non-zero exit fails the workflow step, which fails the plan, which blocks the
apply.

This gate compares an estimate; it does not produce one. Producing one needs a
pricing source, which is a deployment decision rather than a rule, so the
estimator writes its output and this step judges it.

Deny by default applies: an estimate that is absent, unreadable, or in another
currency exits non-zero rather than letting the plan through ungated. The one
thing worse than no cost gate is a cost gate that passes when it cannot tell.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Exit codes are the contract. A caller distinguishes "refused" from "could not
# run", because the second is a misconfiguration to fix rather than a plan to
# change.
EXIT_ALLOWED = 0
EXIT_REFUSED = 1
EXIT_UNUSABLE = 2


class EstimateError(Exception):
    """The estimate could not be read or understood."""


@dataclass(frozen=True)
class Estimate:
    """A projected monthly cost for one plan."""

    monthly_usd: float
    currency: str


def parse_estimate(document: Any) -> Estimate:
    """Read an estimator's output.

    Accepts Infracost's `totalMonthlyCost`/`currency` shape and the plain
    `monthly_usd`/`currency` form, since the estimator is a deployment choice.

    @param document: the decoded estimator output.
    @returns the estimate.
    @raises EstimateError: when no monthly total can be read, or it is not a
        finite non-negative number. A malformed estimate is refused rather than
        coerced, because a coerced zero would pass every ceiling.
    """
    if not isinstance(document, dict):
        raise EstimateError("estimate must be a JSON object")

    raw = document.get("totalMonthlyCost", document.get("monthly_usd"))
    if raw is None:
        raise EstimateError("estimate carries no totalMonthlyCost or monthly_usd")
    try:
        monthly = float(raw)
    except (TypeError, ValueError) as cause:
        raise EstimateError(f"monthly total {raw!r} is not a number") from cause
    if monthly != monthly or monthly in (float("inf"), float("-inf")):
        raise EstimateError("monthly total is not finite")
    if monthly < 0:
        raise EstimateError(f"monthly total {monthly} is negative")

    currency = document.get("currency", "USD")
    if not isinstance(currency, str) or currency == "":
        raise EstimateError("currency must be a non-empty string")
    return Estimate(monthly_usd=monthly, currency=currency)


def decide(estimate: Estimate, ceiling_usd: float) -> tuple[int, str]:
    """Judge one estimate against the ceiling.

    @param estimate: the estimator's output.
    @param ceiling_usd: the monthly ceiling this deployment permits.
    @returns the exit code and the single line to print. The line names both
        figures, because an agent told only "too expensive" cannot act on it.
    """
    if estimate.currency != "USD":
        return (
            EXIT_REFUSED,
            f"refused: estimate is in {estimate.currency}; the ceiling is written in USD",
        )
    if estimate.monthly_usd > ceiling_usd:
        return (
            EXIT_REFUSED,
            f"refused: estimated ${estimate.monthly_usd:.2f}/mo exceeds the "
            f"${ceiling_usd:.2f}/mo ceiling",
        )
    return (
        EXIT_ALLOWED,
        f"allowed: estimated ${estimate.monthly_usd:.2f}/mo is within the "
        f"${ceiling_usd:.2f}/mo ceiling",
    )


def run(argv: list[str] | None = None) -> int:
    """Entry point.

    @param argv: arguments excluding the program name; defaults to `sys.argv`.
    @returns the process exit code.
    """
    parser = argparse.ArgumentParser(
        prog="agent-iac-cost-gate",
        description="Refuse a plan whose estimated monthly cost exceeds the ceiling.",
    )
    parser.add_argument("--estimate", required=True, type=Path, help="estimator output JSON")
    parser.add_argument("--ceiling-usd", required=True, type=float, help="monthly ceiling in USD")
    parser.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="plan representation, reported alongside the verdict when given",
    )
    args = parser.parse_args(argv)

    if args.ceiling_usd < 0:
        print("unusable: --ceiling-usd must not be negative", file=sys.stderr)
        return EXIT_UNUSABLE

    if not args.estimate.exists():
        # Deny by default: no estimate is a refusal, not a pass.
        print(
            f"refused: no cost estimate at {args.estimate}, and a "
            f"${args.ceiling_usd:.2f}/mo ceiling applies"
        )
        return EXIT_REFUSED

    try:
        estimate = parse_estimate(json.loads(args.estimate.read_text()))
    except (OSError, json.JSONDecodeError) as cause:
        print(f"refused: cost estimate could not be read ({cause})")
        return EXIT_REFUSED
    except EstimateError as cause:
        print(f"refused: cost estimate is unusable ({cause})")
        return EXIT_REFUSED

    code, line = decide(estimate, args.ceiling_usd)
    if args.plan is not None and args.plan.exists():
        try:
            changes = json.loads(args.plan.read_text()).get("resource_changes") or []
            line = f"{line} across {len(changes)} planned resource changes"
        except (OSError, json.JSONDecodeError, AttributeError):
            # The plan is context for the message only; its absence or
            # malformation must not change the cost verdict.
            pass
    print(line)
    return code


def main() -> None:
    """Console entry point."""
    raise SystemExit(run())
