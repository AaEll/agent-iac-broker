output "apply_role_arn" {
  description = <<-EOT
    The only credential able to mutate infrastructure. Pass it to the
    control-plane module as agent_plane_apply_role_arn.
  EOT
  value       = aws_iam_role.apply.arn
}

output "agent_read_role_arn" {
  description = "The agent's read-only view of this account."
  value       = aws_iam_role.agent_read.arn
}

output "account_id" {
  description = "The agent-plane account this module configured."
  value       = data.aws_caller_identity.current.account_id
}

output "reaper_rule_arn" {
  description = "The lease reaper's schedule rule. Its target is the deployment's own sweeper."
  value       = aws_cloudwatch_event_rule.reaper.arn
}
