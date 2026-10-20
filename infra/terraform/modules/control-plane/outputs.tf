output "cluster_arn" {
  description = "ECS cluster both task families run in."
  value       = aws_ecs_cluster.this.arn
}

output "agent_task_definition_arn" {
  description = "Task definition a supervisor runs to start one agent task."
  value       = aws_ecs_task_definition.agent.arn
}

output "agent_task_role_arn" {
  description = "The agent's identity. Holds no credential able to mutate infrastructure."
  value       = aws_iam_role.agent.arn
}

output "atlantis_task_role_arn" {
  description = <<-EOT
    The applier's identity. The agent-plane module trusts this principal to
    assume its apply role, so it is the one value the two planes share.
  EOT
  value       = aws_iam_role.atlantis.arn
}

output "atlantis_internal_url" {
  description = "Where the agent reaches the applier. No public ingress."
  value       = "http://atlantis.${aws_service_discovery_private_dns_namespace.this.name}:4141"
}

output "atlantis_api_secret_arn" {
  description = "Secrets Manager ARN of the X-Atlantis-Token. The whole access rule for the API."
  value       = aws_secretsmanager_secret.atlantis_api.arn
}

output "outcome_table_name" {
  description = "Where the harness reads a verdict and enforces idempotency."
  value       = aws_dynamodb_table.outcomes.name
}

output "state_bucket" {
  description = "Remote state for the infrastructure the agent proposes changes to."
  value       = aws_s3_bucket.state.id
}

output "task_security_group_id" {
  description = "Security group both task families run in; Atlantis admits only this group."
  value       = aws_security_group.tasks.id
}

output "subnet_ids" {
  description = "Subnets in use, whether injected or created."
  value       = local.subnet_ids
}
