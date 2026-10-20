# EC2 instance families, and the unknown-attribute refusal that keeps the
# check from being skipped on a computed instance type.
package main

import rego.v1

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_instance"
	establishing(rc)
	unknown(rc, "instance_type")
	msg := sprintf(
		"%s: instance_type is unknown until apply, so the instance family cannot be checked [attribute_unknown]",
		[rc.address],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_instance"
	establishing(rc)
	not unknown(rc, "instance_type")
	not is_string(rc.change.after.instance_type)
	msg := sprintf(
		"%s: instance_type is absent, so the instance family cannot be checked [attribute_missing]",
		[rc.address],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_instance"
	establishing(rc)
	t := rc.change.after.instance_type
	is_string(t)
	family := split(t, ".")[0]
	not family in allowed_instance_families
	msg := sprintf(
		"%s: instance family %q is not allowed (%s) [instance_family_not_allowed]",
		[rc.address, family, t],
	)
}
