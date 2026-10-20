"""Policy-and-cost gated Terraform apply broker for agentic systems.

The agent proposes a commit; this service fetches it, plans it, gates the whole
plan, and applies it. It holds the only credential in the system that can
mutate infrastructure, and it trusts no caller: a request carrying a claim of
prior approval is ignored, and the gate runs regardless.
"""

from .gate import Refusal, Verdict, evaluate, evaluate_document
from .plan import Plan, PlanParseError, ResourceChange, parse_plan
from .policy import CostEstimate, GatePolicy

__all__ = [
    "CostEstimate",
    "GatePolicy",
    "Plan",
    "PlanParseError",
    "Refusal",
    "ResourceChange",
    "Verdict",
    "evaluate",
    "evaluate_document",
    "parse_plan",
]
