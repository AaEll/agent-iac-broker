# Shared pieces: networking resolution, the cluster, logs, and the record the
# harness reads a verdict from.

locals {
  # Constructed, not referenced: see agent_plane_account_id. The agent-plane
  # module names this role `${name_prefix}-apply`, so the two line up only when
  # both are called with the same prefix.
  agent_plane_apply_role_arn = "arn:aws:iam::${var.agent_plane_account_id}:role/${var.name_prefix}-apply"

  create_vpc = var.network_mode == "create_vpc"
  vpc_id     = local.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = local.create_vpc ? aws_subnet.private[*].id : var.subnet_ids

  tags = merge(var.tags, {
    "osf:component"  = "control-plane"
    "osf:managed-by" = "terraform"
  })
}

# Fail at plan time rather than at apply when an injected-networking
# deployment forgot its inputs.
resource "null_resource" "network_inputs" {
  count = local.create_vpc ? 0 : 1

  lifecycle {
    precondition {
      condition     = var.vpc_id != null && length(var.subnet_ids) > 0
      error_message = "network_mode=shared_subnets requires vpc_id and at least one subnet_id."
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-control" })

  lifecycle {
    precondition {
      condition     = var.vpc_cidr != null
      error_message = "network_mode=create_vpc requires vpc_cidr."
    }
  }
}

resource "aws_subnet" "private" {
  count = local.create_vpc ? 2 : 0

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.tags, { Name = "${var.name_prefix}-control-private-${count.index}" })
}

# One security group for both task families. Egress only: nothing outside the
# plane initiates a connection inward, and Atlantis is reached from the agent
# task inside this group.
resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-control-tasks"
  description = "Atlantis and agent tasks. Egress only; Atlantis is reachable only from this group."
  vpc_id      = local.vpc_id

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Model endpoint, git forge, AWS APIs."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Atlantis has no per-request identity, so its API token is the whole access
# rule. Only the agent task's own security group may reach the port at all.
resource "aws_vpc_security_group_ingress_rule" "atlantis_from_tasks" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Atlantis API, from the agent task only."
  from_port                    = 4141
  to_port                      = 4141
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-control"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "atlantis" {
  name              = "/${var.name_prefix}/atlantis"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/${var.name_prefix}/agent"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# The outcome record. Atlantis keeps no session-scoped state, so this is where
# the harness reads a verdict and where idempotency is enforced: the key is the
# session and the resolved commit, because Atlantis re-plans on every apply and
# a duplicate request would otherwise be a second real apply.
resource "aws_dynamodb_table" "outcomes" {
  name         = "${var.name_prefix}-iac-outcomes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.tags
}

# The API secret is generated here rather than supplied: it is machine-to-
# machine, never typed by a person, and keeping it out of inputs keeps it out
# of Terragrunt files and state dumps that get shared.
resource "random_password" "atlantis_api_secret" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "atlantis_api" {
  name        = "${var.name_prefix}-atlantis-api-secret"
  description = "X-Atlantis-Token. Buys plan and apply; cannot override the gate."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "atlantis_api" {
  secret_id     = aws_secretsmanager_secret.atlantis_api.id
  secret_string = random_password.atlantis_api_secret.result
}
