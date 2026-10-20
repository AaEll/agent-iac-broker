# The property that is easiest to break and hardest to notice: with no
# deployment data supplied, the sets must refuse rather than admit.
#
# This existed as a bug once. The accessors were written with `object.get`
# over `data.osf`, which is undefined when no data is supplied at all, so
# every rule body referencing one silently failed to evaluate and an
# unconfigured gate admitted everything. These tests pin the fix.
package main

import rego.v1

instance_plan := {"resource_changes": [{
	"address": "aws_instance.web",
	"mode": "managed",
	"type": "aws_instance",
	"name": "web",
	"change": {
		"actions": ["create"],
		"after": {"instance_type": "m7i.large"},
		"after_unknown": {},
	},
}]}

configured := {
	"allowed_resource_types": ["aws_instance"],
	"allowed_instance_families": ["m7i"],
}

test_no_data_refuses_an_otherwise_fine_plan if {
	count(deny) > 0 with input as instance_plan
}

test_no_data_names_the_resource_type_rule if {
	some msg in deny with input as instance_plan
	contains(msg, "resource_type_not_allowed")
}

test_configured_data_admits_it if {
	count(deny) == 0 with input as instance_plan with data.osf as configured
}

test_empty_allowlists_refuse if {
	count(deny) > 0 with input as instance_plan
		with data.osf as {"allowed_resource_types": [], "allowed_instance_families": []}
}

test_network_control_is_refused_even_when_allowlisted if {
	plan := {"resource_changes": [{
		"address": "aws_route_table.r",
		"mode": "managed",
		"type": "aws_route_table",
		"name": "r",
		"change": {"actions": ["create"], "after": {}, "after_unknown": {}},
	}]}
	some msg in deny with input as plan
		with data.osf as {"allowed_resource_types": ["aws_route_table"]}
	contains(msg, "network_control_refused")
}

test_an_unknown_instance_type_refuses_rather_than_skipping if {
	plan := {"resource_changes": [{
		"address": "aws_instance.computed",
		"mode": "managed",
		"type": "aws_instance",
		"name": "computed",
		"change": {
			"actions": ["create"],
			"after": {},
			"after_unknown": {"instance_type": true},
		},
	}]}
	some msg in deny with input as plan with data.osf as configured
	contains(msg, "attribute_unknown")
}

test_a_data_source_read_is_not_judged if {
	plan := {"resource_changes": [{
		"address": "data.aws_ami.x",
		"mode": "data",
		"type": "aws_ami",
		"name": "x",
		"change": {"actions": ["read"], "after": {}, "after_unknown": {}},
	}]}
	count(deny) == 0 with input as plan
}
