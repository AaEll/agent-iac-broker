"""The Atlantis API contract, asserted against recorded responses.

These fixtures are real responses from Atlantis 0.48.1, captured during the
evaluation spike and scrubbed of identifiers. They exist because the contract
this design leans on is partly undocumented upstream: the `Command` enum is not
published, and a refused apply is signalled by an internal message rather than a
stable error code.

That makes the contract brittle in a specific way, so the brittleness is pinned
here. If an Atlantis upgrade reshapes a response or rewords a refusal, these
assertions fail — which is the point. The alternative is an upgrade silently
turning a refused apply into a success.

The rule under test is the one a client gets wrong by default: a refusal
arrives with a null top-level `Error` and an empty top-level `Failure`, placing
the refusal only in a per-project field.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

# The version these responses were captured from. Changing the deployed image
# without re-recording is what this constant exists to make visible.
ATLANTIS_VERSION = "0.48.1"

FIXTURES = Path(__file__).parent / "fixtures" / "atlantis"

# Atlantis reports the stage as an integer with no published mapping; these
# three were read from live responses.
COMMAND_APPLY = 0
COMMAND_PLAN = 1
COMMAND_POLICY_CHECK = 3

# Verbatim refusal messages. Matched as strings because Atlantis offers no code.
POLICY_REFUSED = "Some policy sets did not pass."
APPLY_BLOCKED = "All policies must pass for project before running apply."


def recorded(name: str) -> Any:
    """Load one recorded Atlantis response."""
    return json.loads((FIXTURES / f"{name}.json").read_text())


def is_refused(response: Any) -> bool:
    """Decide whether an Atlantis response refused the request.

    This is the predicate a client must implement, stated once here so the
    recorded responses prove it. A response is refused when any project result
    carries a non-empty `Failure` or a non-null `Error`, and an absent or empty
    `ProjectResults` counts as refused rather than as nothing-to-do.

    @param response: a decoded `/api/plan` or `/api/apply` response.
    @returns whether the request failed to achieve what it asked for.
    """
    if response.get("Error") is not None:
        return True
    if response.get("Failure"):
        return True
    results = response.get("ProjectResults") or []
    if not results:
        return True
    return any(r.get("Failure") or r.get("Error") is not None for r in results)


ALL_FIXTURES = [
    "plan-policy-passed",
    "plan-policy-refused",
    "apply-succeeded",
    "apply-blocked-by-policy",
]


class TestTopLevelIsNotTheSignal:
    """The footgun: every refusal looks benign at the top level."""

    @pytest.mark.parametrize("name", ALL_FIXTURES)
    def test_top_level_is_benign_even_when_refused(self, name: str) -> None:
        d = recorded(name)
        assert d.get("Error") is None
        assert d.get("Failure") == ""

    def test_a_client_reading_only_the_top_level_sees_success(self) -> None:
        # Stated as a test so the trap is executable, not just documented:
        # the blocked apply is indistinguishable from the succeeded one at the
        # top level, and only the per-project field separates them.
        blocked = recorded("apply-blocked-by-policy")
        ok = recorded("apply-succeeded")
        naive = lambda d: d.get("Error") is None and not d.get("Failure")  # noqa: E731
        assert naive(blocked) == naive(ok) is True
        assert is_refused(blocked) is True
        assert is_refused(ok) is False

    def test_plans_deleted_is_not_a_failure_signal(self) -> None:
        for name in ALL_FIXTURES:
            assert recorded(name).get("PlansDeleted") is False


class TestRefusalDetection:
    def test_a_blocked_apply_is_refused(self) -> None:
        assert is_refused(recorded("apply-blocked-by-policy")) is True

    def test_a_failed_policy_check_is_refused(self) -> None:
        assert is_refused(recorded("plan-policy-refused")) is True

    def test_a_successful_apply_is_not_refused(self) -> None:
        assert is_refused(recorded("apply-succeeded")) is False

    def test_a_passing_plan_is_not_refused(self) -> None:
        assert is_refused(recorded("plan-policy-passed")) is False

    def test_empty_project_results_is_refused(self) -> None:
        # Not a recorded case: a response that achieved nothing must never read
        # as success, so the predicate is asserted directly.
        assert is_refused({"Error": None, "Failure": "", "ProjectResults": []}) is True
        assert is_refused({"Error": None, "Failure": ""}) is True


class TestRefusalStrings:
    """Pinned verbatim. An upstream rewording must fail here."""

    def test_policy_check_refusal_string(self) -> None:
        d = recorded("plan-policy-refused")
        failures = [r.get("Failure") for r in d["ProjectResults"]]
        assert POLICY_REFUSED in failures

    def test_apply_blocked_string(self) -> None:
        d = recorded("apply-blocked-by-policy")
        failures = [r.get("Failure") for r in d["ProjectResults"]]
        assert APPLY_BLOCKED in failures


class TestCommandEnum:
    def test_a_plan_request_reports_plan_and_policy_check(self) -> None:
        # One project, two results: the plan and the gate.
        commands = [r.get("Command") for r in recorded("plan-policy-refused")["ProjectResults"]]
        assert commands == [COMMAND_PLAN, COMMAND_POLICY_CHECK]

    def test_an_apply_request_reports_apply(self) -> None:
        for name in ("apply-succeeded", "apply-blocked-by-policy"):
            commands = [r.get("Command") for r in recorded(name)["ProjectResults"]]
            assert commands == [COMMAND_APPLY]


class TestPolicyCheckResult:
    def test_passed_is_the_field_to_branch_on(self) -> None:
        refused = recorded("plan-policy-refused")["ProjectResults"][-1]
        passed = recorded("plan-policy-passed")["ProjectResults"][-1]
        assert refused["PolicyCheckResults"]["PolicySetResults"][0]["Passed"] is False
        assert passed["PolicyCheckResults"]["PolicySetResults"][0]["Passed"] is True

    def test_a_passing_check_still_reports_results(self) -> None:
        # Absence of PolicyCheckResults means the stage did not run, which is
        # what `--enable-policy-checks` being unset looks like. It must not be
        # confused with a pass.
        passed = recorded("plan-policy-passed")["ProjectResults"][-1]
        assert passed["PolicyCheckResults"] is not None

    def test_the_refusal_reason_is_prose_not_structure(self) -> None:
        # PolicyOutput is conftest's human text. It is carried to the model
        # verbatim and never parsed to decide an outcome.
        out = recorded("plan-policy-refused")["ProjectResults"][-1]["PolicyCheckResults"][
            "PolicySetResults"
        ][0]["PolicyOutput"]
        assert isinstance(out, str)
        assert "FAIL" in out

    def test_the_override_command_is_advertised_but_not_reachable(self) -> None:
        # Atlantis names approve_policies in the result. The spike confirmed
        # /api/approve_policies is not a registered route, which is what keeps
        # every agent on the API path equally bounded. If a future version
        # exposes it, this field is the reminder to re-check.
        results = recorded("plan-policy-refused")["ProjectResults"][-1]["PolicyCheckResults"]
        assert results["ApprovePoliciesCmd"].startswith("atlantis approve_policies")
