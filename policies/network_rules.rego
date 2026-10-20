# Administrative ports exposed to any address. Egress to the world is
# ordinary; only ingress is judged.
package main

import rego.v1

ingress_rule_types := {"aws_security_group_rule", "aws_vpc_security_group_ingress_rule"}

cidr_keys := ["cidr_blocks", "ipv6_cidr_blocks", "cidr_ipv4", "cidr_ipv6"]

# aws_security_group_rule carries a direction; the newer dedicated ingress
# resource is ingress by its type.
judged_ingress(rc) if {
	rc.type == "aws_vpc_security_group_ingress_rule"
}

judged_ingress(rc) if {
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
}

world_open(rc) if {
	some key in cidr_keys
	rc.change.after[key] == any_ipv4
}

world_open(rc) if {
	some key in cidr_keys
	rc.change.after[key] == any_ipv6
}

world_open(rc) if {
	some key in cidr_keys
	some entry in rc.change.after[key]
	entry in {any_ipv4, any_ipv6}
}

# A rule carrying no port bounds at all admits every port, which includes
# every administrative one.
covers_admin_port(rc) if not rc.change.after.from_port
covers_admin_port(rc) if {
	low := rc.change.after.from_port
	high := object.get(rc.change.after, "to_port", low)
	some port in admin_ports
	port >= low
	port <= high
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in ingress_rule_types
	establishing(rc)
	judged_ingress(rc)
	some key in cidr_keys
	unknown(rc, key)
	msg := sprintf(
		"%s: %s is unknown until apply, so exposure of an administrative port cannot be ruled out [attribute_unknown]",
		[rc.address, key],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in ingress_rule_types
	establishing(rc)
	judged_ingress(rc)
	some key in ["from_port", "to_port"]
	unknown(rc, key)
	msg := sprintf(
		"%s: %s is unknown until apply, so exposure of an administrative port cannot be ruled out [attribute_unknown]",
		[rc.address, key],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in ingress_rule_types
	establishing(rc)
	judged_ingress(rc)
	world_open(rc)
	covers_admin_port(rc)
	msg := sprintf(
		"%s: ingress from any address covers an administrative port %v [admin_port_exposed]",
		[rc.address, admin_ports],
	)
}
