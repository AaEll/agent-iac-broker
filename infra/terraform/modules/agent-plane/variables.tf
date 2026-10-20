# This module runs with a provider aimed at the agent-plane account, which is a
# different account from the control plane. That separation is the point: an
# SCP, a budget, and a quota all attach to an account, and none of them attach
# to a VPC.

variable "name_prefix" {
  description = "Prefix for every created resource name."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource that accepts them."
  type        = map(string)
  default     = {}
}

variable "control_plane_account_id" {
  description = <<-EOT
    Account the applier runs in. Its role ARN is constructed from this and
    `name_prefix` rather than taken as that module's output, because each
    module would otherwise depend on the other and neither could be applied
    first. Both must be called with the same `name_prefix`.

    It is the only principal trusted to assume the apply role here.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.control_plane_account_id))
    error_message = "control_plane_account_id must be a 12-digit AWS account id."
  }
}

variable "apply_permissions" {
  description = <<-EOT
    What the applier may do in this account. Broad within the services a
    deployment actually uses, and deliberately explicit: there is no default,
    because a default here would be either uselessly narrow or dangerously
    wide. The network-control denial below is applied regardless of what this
    lists.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.apply_permissions) > 0
    error_message = "apply_permissions must list at least one action."
  }
}

variable "allowed_regions" {
  description = "Regions the applier may act in. Enforced as a condition on every apply action."
  type        = list(string)

  validation {
    condition     = length(var.allowed_regions) > 0
    error_message = "allowed_regions must name at least one region."
  }
}

variable "monthly_budget_usd" {
  description = <<-EOT
    Budget for this account. A backstop, not the spend control: cost data lags
    by hours, so this bounds an overrun rather than preventing one. The
    pre-apply cost gate and the concurrency quotas are what hold promptly.
  EOT
  type        = number

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
  }
}

variable "budget_alert_emails" {
  description = "Addresses notified when the budget threshold is crossed."
  type        = list(string)
  default     = []
}

variable "lease_ttl_hours" {
  description = <<-EOT
    Wall-clock lifetime for a run's resources. The reaper is driven by time
    rather than by billing data, which is why it is the control that actually
    bounds a runaway run.
  EOT
  type        = number
  default     = 24

  validation {
    condition     = var.lease_ttl_hours > 0
    error_message = "lease_ttl_hours must be positive."
  }
}
