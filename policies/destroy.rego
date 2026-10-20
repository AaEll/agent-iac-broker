# Destroys, where the deployment refuses them outright.
package main

import rego.v1

deny contains msg if {
	refuse_delete
	some rc in input.resource_changes
	destroying(rc)
	msg := sprintf(
		"%s: this deployment refuses plans that destroy resources [delete_refused]",
		[rc.address],
	)
}
