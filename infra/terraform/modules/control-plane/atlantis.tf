# Atlantis, the applier. Adopted rather than written, so what this file governs
# is its configuration — and two of its settings are invariants rather than
# options.

locals {
  # The rego `data.osf` document. Rendered from inputs so a deployment's
  # allowlists live in its own Terragrunt inputs, never in the broker image.
  policy_data = yamlencode({ osf = {
    allowed_resource_types    = var.policy_data.allowed_resource_types
    allowed_instance_families = var.policy_data.allowed_instance_families
    admin_ports               = var.policy_data.admin_ports
    refuse_delete             = var.policy_data.refuse_delete
  } })

  # Atlantis server-side repo configuration. Policies are declared here, not in
  # the repository under change, which is what keeps a caller from supplying or
  # weakening a rule. The cost gate rides as a plan step, because conftest sees
  # the plan and Atlantis has no cost concept.
  repo_config = yamlencode({
    repos = [{
      id                 = "/.*/"
      apply_requirements = ["undiverged"]
      workflow           = "osf"
    }]
    policies = {
      owners = { users = var.policy_owner_users }
      policy_sets = [{
        name   = "osf"
        path   = "/etc/osf/policies"
        source = "local"
      }]
    }
    workflows = {
      osf = {
        plan = {
          # The cost step is present only when a ceiling is set. The gate
          # denies by default, so including it without an estimator would
          # refuse every plan on cost.
          steps = concat(
            ["init", "plan"],
            var.monthly_cost_ceiling_usd == null ? [] : [{
              run = join(" ", [
                "agent-iac-cost-gate",
                "--estimate $DIR/.osf/cost-estimate.json",
                "--plan $PLANFILE.json",
                "--ceiling-usd ${var.monthly_cost_ceiling_usd}",
              ])
            }],
          )
        }
        apply = { steps = ["apply"] }
      }
    }
  })
}

resource "aws_ssm_parameter" "policy_data" {
  name        = "/${var.name_prefix}/atlantis/policy-data"
  description = "rego data.osf for the policy sets."
  type        = "String"
  value       = local.policy_data
  tags        = local.tags
}

resource "aws_ssm_parameter" "repo_config" {
  name        = "/${var.name_prefix}/atlantis/repo-config"
  description = "Atlantis server-side repo config: policy sets, workflow, apply requirements."
  type        = "String"
  value       = local.repo_config
  tags        = local.tags
}

# BoltDB wants one writer, so the data directory is an EFS volume and the
# service runs exactly one task with no overlapping deployment. Locks and
# plan files survive a restart; two tasks would corrupt them.
resource "aws_efs_file_system" "atlantis" {
  creation_token = "${var.name_prefix}-atlantis-data"
  encrypted      = true
  tags           = merge(local.tags, { Name = "${var.name_prefix}-atlantis-data" })
}

resource "aws_efs_mount_target" "atlantis" {
  count = length(local.subnet_ids)

  file_system_id  = aws_efs_file_system.atlantis.id
  subnet_id       = local.subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-atlantis-efs"
  description = "NFS from the Atlantis task only."
  vpc_id      = local.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_tasks" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the task security group."
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_ecs_task_definition" "atlantis" {
  family                   = "${var.name_prefix}-atlantis"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.atlantis_cpu
  memory                   = var.atlantis_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.atlantis.arn
  tags                     = local.tags

  volume {
    name = "data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.atlantis.id
      transit_encryption = "ENABLED"
    }
  }

  container_definitions = jsonencode([{
    name      = "atlantis"
    image     = var.broker_image
    essential = true

    # Written as flags rather than env so the invariants are legible in a diff.
    command = concat(
      [
        "server",
        "--atlantis-url=http://localhost:4141",
        "--port=4141",
        "--data-dir=/atlantis-data",
        "--repo-config=/atlantis-data/repo-config.yaml",
        # The difference between a gate and no gate. Without it the policy
        # stage does not run at all and a violating plan applies cleanly.
        "--enable-policy-checks",
        # Keeps the runtime on MPL-2.0 rather than Terraform's BUSL-1.1.
        "--default-tf-distribution=opentofu",
        # A second destructive apply path whose gating is unverified. Left off.
        "--enable-drift-detection=false",
        "--enable-drift-remediation=false",
        "--write-git-creds",
      ],
      [for repo in var.repo_allowlist : "--repo-allowlist=${repo}"],
    )

    portMappings = [{ containerPort = 4141, protocol = "tcp" }]

    mountPoints = [{
      sourceVolume  = "data"
      containerPath = "/atlantis-data"
      readOnly      = false
    }]

    environment = [
      { name = "ATLANTIS_GH_USER", value = var.git_user },
      { name = "AWS_REGION", value = data.aws_region.current.region },
      { name = "OSF_APPLY_ROLE_ARN", value = local.agent_plane_apply_role_arn },
      { name = "OSF_STATE_BUCKET", value = aws_s3_bucket.state.id },
      { name = "OSF_STATE_LOCK_TABLE", value = aws_dynamodb_table.state_lock.name },
      { name = "OSF_POLICY_DATA_PARAM", value = aws_ssm_parameter.policy_data.name },
      { name = "OSF_REPO_CONFIG_PARAM", value = aws_ssm_parameter.repo_config.name },
    ]

    secrets = [
      { name = "ATLANTIS_GH_TOKEN", valueFrom = var.git_token_secret_arn },
      { name = "ATLANTIS_API_SECRET", valueFrom = aws_secretsmanager_secret.atlantis_api.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.atlantis.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "atlantis"
      }
    }
  }])
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.name_prefix}.osf.internal"
  description = "Internal names for the control plane."
  vpc         = local.vpc_id
  tags        = local.tags
}

resource "aws_service_discovery_service" "atlantis" {
  name = "atlantis"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  tags = local.tags
}

resource "aws_ecs_service" "atlantis" {
  name            = "${var.name_prefix}-atlantis"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.atlantis.arn
  launch_type     = "FARGATE"

  # Exactly one writer for BoltDB on EFS. The deployment-percent pair prevents
  # a rolling update from briefly running two.
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.atlantis.arn
  }

  tags = local.tags

  depends_on = [aws_efs_mount_target.atlantis]
}

data "aws_region" "current" {}
