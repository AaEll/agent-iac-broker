# Shared helpers for every rule set.
#
# Two properties live here because every rule depends on them:
#
# `mutating` narrows judgement to managed resources whose real state the plan
# changes. A data-source read and a no-op change nothing.
#
# `unknown` is the one that is easy to get wrong. Terraform marks values it
# cannot resolve until apply in `change.after_unknown`, encoding a fully
# unknown scalar as `true` and a known map as `{}`. A rule that reads an
# attribute without consulting it silently skips the change it exists to
# refuse, so every rule judging an attribute refuses when that attribute is
# unknown.
#
# Deployment configuration arrives as `data.osf`. Every accessor defaults to
# empty rather than permissive: an unconfigured deployment refuses everything,
# which is the behaviour a half-configured gate should have.
package main

import rego.v1

mutating(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update", "delete"}
}

destroying(rc) if {
	rc.mode == "managed"
	"delete" in rc.change.actions
}

# Creating or updating, as distinct from destroying: a rule about an attribute's
# value has nothing to judge on a resource that is going away.
establishing(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update"}
}

unknown(rc, key) if rc.change.after_unknown[key] == true

# Each accessor is a total rule with a `default`, not an `object.get` over
# `data.osf`. With no data supplied at all, `object.get` on an undefined value
# is itself undefined, so a rule body referencing it cannot evaluate and
# silently does not fire — an unconfigured deployment would admit everything
# while appearing to have a gate. A `default` makes the accessor total, so an
# empty allowlist refuses instead.
default allowed_resource_types := []

allowed_resource_types := data.osf.allowed_resource_types

default allowed_instance_families := []

allowed_instance_families := data.osf.allowed_instance_families

default admin_ports := [22, 3389]

admin_ports := data.osf.admin_ports

default refuse_delete := false

refuse_delete := data.osf.refuse_delete

# Resource types that reshape the network the agent runs inside. Refused
# unconditionally: the agent may build within its plane, but altering the
# plane's own boundary is a different act, so listing one of these in the
# allowlist does not permit it.
network_control_types := {
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

any_ipv4 := "0.0.0.0/0"

any_ipv6 := "::/0"
