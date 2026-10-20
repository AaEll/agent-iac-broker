# Which resource types a plan may touch at all.
package main

import rego.v1

deny contains msg if {
	some rc in input.resource_changes
	mutating(rc)
	rc.type in network_control_types
	msg := sprintf(
		"%s: %s reshapes the agent plane's own network boundary, which the agent may not alter [network_control_refused]",
		[rc.address, rc.type],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	mutating(rc)
	not rc.type in network_control_types
	not rc.type in allowed_resource_types
	msg := sprintf(
		"%s: %s is not in the allowed resource types [resource_type_not_allowed]",
		[rc.address, rc.type],
	)
}
