"""The Terraform plan representation the gate reads.

The input is the JSON from `terraform show -json <planfile>`, not the streaming
`terraform plan -json` log: the former is the machine-readable plan, the latter
is a progress log whose `planned_change` events omit attribute values the gate
needs. Only the fields the gate actually reads are modelled here; unknown keys
are ignored so a newer `format_version` does not break parsing.

The one subtlety is `after_unknown`. Terraform marks attributes it cannot
resolve until apply, and an attribute the gate wants to judge may be among
them. Those attributes are reported as unknown rather than absent, because a
rule that silently skips an unresolvable value would admit exactly the change
it exists to refuse.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# Terraform plan actions. "no-op" and "read" change nothing the gate judges.
MUTATING_ACTIONS = frozenset({"create", "update", "delete"})


class PlanParseError(ValueError):
    """The supplied document is not a Terraform plan representation."""


@dataclass(frozen=True)
class ResourceChange:
    """One planned change to one resource."""

    address: str
    mode: str
    type: str
    name: str
    actions: tuple[str, ...]
    after: dict[str, Any] = field(default_factory=dict)
    before: dict[str, Any] = field(default_factory=dict)
    after_unknown: dict[str, Any] = field(default_factory=dict)

    @property
    def is_managed(self) -> bool:
        """Whether this is a managed resource rather than a data source."""
        return self.mode == "managed"

    @property
    def is_mutating(self) -> bool:
        """Whether the plan changes this resource's real state."""
        return any(action in MUTATING_ACTIONS for action in self.actions)

    @property
    def is_delete(self) -> bool:
        """Whether the plan destroys this resource."""
        return "delete" in self.actions

    def attribute(self, key: str) -> tuple[Any | None, bool]:
        """Read one post-apply attribute.

        @param key: the attribute name as Terraform spells it.
        @returns a pair of the value and whether Terraform left it unknown. An
            unknown attribute returns `(None, True)`; an absent one returns
            `(None, False)`, which a caller may legitimately treat as a default.
        """
        if self.after_unknown.get(key) is True:
            return None, True
        return self.after.get(key), False


@dataclass(frozen=True)
class Plan:
    """A parsed Terraform plan representation."""

    format_version: str
    terraform_version: str
    resource_changes: tuple[ResourceChange, ...]

    @property
    def mutating_changes(self) -> tuple[ResourceChange, ...]:
        """Managed resources whose real state this plan changes."""
        return tuple(c for c in self.resource_changes if c.is_managed and c.is_mutating)


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def parse_plan(document: Any) -> Plan:
    """Parse `terraform show -json` output into a {@link Plan}.

    @param document: the already-decoded JSON document.
    @returns the parsed plan, carrying only the fields the gate reads.
    @raises PlanParseError: when the document is not an object, or when
        `resource_changes` is present but not a list of objects. A plan with no
        `resource_changes` key is accepted as an empty plan, which is what
        Terraform emits for a no-op.
    """
    if not isinstance(document, dict):
        raise PlanParseError("plan must be a JSON object")

    raw_changes = document.get("resource_changes", [])
    if not isinstance(raw_changes, list):
        raise PlanParseError("resource_changes must be a list")

    changes: list[ResourceChange] = []
    for index, raw in enumerate(raw_changes):
        if not isinstance(raw, dict):
            raise PlanParseError(f"resource_changes[{index}] must be an object")
        change = _as_dict(raw.get("change"))
        actions = change.get("actions", [])
        if not isinstance(actions, list):
            raise PlanParseError(f"resource_changes[{index}].change.actions must be a list")
        address = raw.get("address")
        if not isinstance(address, str) or address == "":
            raise PlanParseError(f"resource_changes[{index}].address must be a non-empty string")
        resource_type = raw.get("type")
        if not isinstance(resource_type, str) or resource_type == "":
            raise PlanParseError(f"{address}: type must be a non-empty string")
        changes.append(
            ResourceChange(
                address=address,
                mode=raw.get("mode", "managed"),
                type=resource_type,
                name=raw.get("name", ""),
                actions=tuple(str(a) for a in actions),
                after=_as_dict(change.get("after")),
                before=_as_dict(change.get("before")),
                after_unknown=_as_dict(change.get("after_unknown")),
            )
        )

    return Plan(
        format_version=str(document.get("format_version", "")),
        terraform_version=str(document.get("terraform_version", "")),
        resource_changes=tuple(changes),
    )
