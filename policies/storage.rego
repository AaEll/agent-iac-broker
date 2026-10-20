# Buckets reachable from outside the account, by either route: a false flag on
# the public-access block, or a public-read ACL. Terraform still accepts `acl`
# on bucket resources, so a plan can expose objects without ever touching the
# block.
package main

import rego.v1

public_access_block_flags := [
	"block_public_acls",
	"block_public_policy",
	"ignore_public_acls",
	"restrict_public_buckets",
]

public_acls := {"public-read", "public-read-write", "authenticated-read"}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_s3_bucket_public_access_block"
	establishing(rc)
	some flag in public_access_block_flags
	unknown(rc, flag)
	msg := sprintf(
		"%s: %s is unknown until apply, so public access cannot be ruled out [attribute_unknown]",
		[rc.address, flag],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_s3_bucket_public_access_block"
	establishing(rc)
	some flag in public_access_block_flags
	rc.change.after[flag] == false
	msg := sprintf(
		"%s: %s is false, which leaves a route to public objects [public_bucket_refused]",
		[rc.address, flag],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in {"aws_s3_bucket_acl", "aws_s3_bucket"}
	establishing(rc)
	unknown(rc, "acl")
	msg := sprintf(
		"%s: acl is unknown until apply, so public access cannot be ruled out [attribute_unknown]",
		[rc.address],
	)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in {"aws_s3_bucket_acl", "aws_s3_bucket"}
	establishing(rc)
	acl := rc.change.after.acl
	acl in public_acls
	msg := sprintf(
		"%s: acl %s exposes the bucket beyond the account [public_bucket_refused]",
		[rc.address, acl],
	)
}
