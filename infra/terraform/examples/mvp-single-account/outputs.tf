output "atlantis_internal_url" {
  description = "Reachable only from inside the task security group."
  value       = module.control_plane.atlantis_internal_url
}

output "atlantis_api_secret_arn" {
  description = "Read this to get the X-Atlantis-Token for driving the trial."
  value       = module.control_plane.atlantis_api_secret_arn
}

output "cluster_arn" {
  description = "Where to run the one-off task that drives the API from inside the VPC."
  value       = module.control_plane.cluster_arn
}

output "task_security_group_id" {
  description = "The group Atlantis admits. A driver task must run in it."
  value       = module.control_plane.task_security_group_id
}

output "subnet_ids" {
  description = "Subnets the module created."
  value       = module.control_plane.subnet_ids
}

output "apply_role_arn" {
  description = "The apply role, in this same account for the trial."
  value       = module.agent_plane.apply_role_arn
}
