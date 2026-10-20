# Remote state for the infrastructure Atlantis applies. Not the state of this
# module — that belongs to whatever runs this — but the state of the client
# workloads the agent proposes changes to.
#
# It lives in the control plane rather than the agent plane deliberately: the
# agent has read-only access in its own account and none here, so it cannot
# read or corrupt the state describing what it is changing.

resource "aws_s3_bucket" "state" {
  bucket        = "${var.name_prefix}-iac-state"
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "state_lock" {
  name         = "${var.name_prefix}-iac-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.tags
}
