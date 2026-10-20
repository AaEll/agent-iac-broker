# The agent: a task definition, not a service. One task per run, started by
# whatever supervises runs — Step Functions, a schedule, or a direct RunTask —
# which is deliberately not fixed here.
#
# Its authority is the Atlantis API token and nothing else. It cannot mutate
# infrastructure, and an explicit deny in iam.tf keeps it from reaching the
# role that can.

resource "aws_ecs_task_definition" "agent" {
  family                   = "${var.name_prefix}-agent"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.agent_cpu
  memory                   = var.agent_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.agent.arn
  tags                     = local.tags

  container_definitions = jsonencode([{
    name      = "agent"
    image     = var.agent_image
    essential = true

    environment = [
      # The applier is reached by its internal name; it has no public ingress
      # and its security group admits only this task's group.
      {
        name  = "OSF_ATLANTIS_BASE_URL"
        value = "http://atlantis.${aws_service_discovery_private_dns_namespace.this.name}:4141"
      },
      { name = "OSF_OUTCOME_TABLE", value = aws_dynamodb_table.outcomes.name },
      { name = "AWS_REGION", value = data.aws_region.current.region },
      # Confinement stays on. The container is a boundary, not a substitute
      # for one, and the harness fails closed rather than running unconfined.
      { name = "DSH_PERMISSION_MODE", value = "workspace-write" },
    ]

    secrets = [
      { name = "FIREWORKS_API_KEY", valueFrom = var.model_api_key_secret_arn },
      { name = "OSF_ATLANTIS_API_SECRET", valueFrom = aws_secretsmanager_secret.atlantis_api.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.agent.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "agent"
      }
    }
  }])
}
