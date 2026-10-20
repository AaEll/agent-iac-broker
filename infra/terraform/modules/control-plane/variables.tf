# Nothing here carries an account, region, CIDR, or name: every one is an
# input, so one module serves every client environment.

variable "name_prefix" {
  description = "Prefix for every created resource name. One deployment per prefix."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource that accepts them."
  type        = map(string)
  default     = {}
}

# ---- Networking: injected, because the client owns routing ----

variable "network_mode" {
  description = <<-EOT
    Where the control plane runs. `shared_subnets` consumes subnets the client's
    networking team provides, which is the default because they keep route
    control. `create_vpc` provisions one, for an environment that has none.
  EOT
  type        = string
  default     = "shared_subnets"

  validation {
    condition     = contains(["shared_subnets", "create_vpc"], var.network_mode)
    error_message = "network_mode must be shared_subnets or create_vpc."
  }
}

variable "vpc_id" {
  description = "VPC to deploy into. Required when network_mode is shared_subnets."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = <<-EOT
    Private subnets for the Atlantis service and the agent task. Required when
    network_mode is shared_subnets. These must reach the model endpoint and the
    git forge, which in a private subnet means a NAT gateway or a proxy.
  EOT
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR for the created VPC. Required when network_mode is create_vpc."
  type        = string
  default     = null
}

# ---- Images: pinned by digest ----

variable "broker_image" {
  description = <<-EOT
    The broker image — Atlantis plus the policy sets, conftest, and the cost
    gate. Pin by digest rather than tag: a refused apply is signalled by an
    internal Atlantis message, so a version change can turn a refusal into a
    success without any configuration changing.
  EOT
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.broker_image))
    error_message = "broker_image must be pinned by digest (repository@sha256:...)."
  }
}

variable "agent_image" {
  description = "The harness image that runs one agent task. Pin by digest."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.agent_image))
    error_message = "agent_image must be pinned by digest (repository@sha256:...)."
  }
}

# ---- The gate's own configuration ----

variable "repo_allowlist" {
  description = <<-EOT
    Repositories Atlantis will act on, in its own allowlist syntax. This is the
    outer bound on what any agent can change, so it is required and has no
    permissive default.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.repo_allowlist) > 0
    error_message = "repo_allowlist must name at least one repository."
  }
}

variable "policy_owner_users" {
  description = <<-EOT
    Git-forge users who may approve a failed policy set. This is the only route
    past the gate, and it is deliberately a human one: no agent identity
    belongs here.
  EOT
  type        = list(string)
  default     = []
}

variable "monthly_cost_ceiling_usd" {
  description = <<-EOT
    Monthly estimate a plan must come in under. `null` omits the cost gate step
    entirely, which a deployment without a cost estimator must do: the gate
    denies by default, so with a ceiling set and nothing producing an estimate
    every plan is refused on cost.

    That omission is deliberate rather than silent — the composed workflow is
    visible in the plan output, and a deployment can see it has no cost gate.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.monthly_cost_ceiling_usd == null || var.monthly_cost_ceiling_usd >= 0
    error_message = "monthly_cost_ceiling_usd must be null or non-negative."
  }
}

variable "policy_data" {
  description = <<-EOT
    Rule-set configuration, rendered to the rego `data.osf` document: allowed
    resource types, allowed instance families, administrative ports, and
    whether destroys are refused. Every key defaults to empty or restrictive in
    the rule sets themselves, so an omitted key refuses rather than admits.
  EOT
  type = object({
    allowed_resource_types    = optional(list(string), [])
    allowed_instance_families = optional(list(string), [])
    admin_ports               = optional(list(number), [22, 3389])
    refuse_delete             = optional(bool, false)
  })
  default = {}
}

# ---- Secrets: referenced, never valued ----

variable "git_user" {
  description = "Git-forge username the applier clones and comments as."
  type        = string
}

variable "git_token_secret_arn" {
  description = "Secrets Manager ARN holding the git-forge token Atlantis clones and comments with."
  type        = string
}

variable "model_api_key_secret_arn" {
  description = "Secrets Manager ARN holding the agent's model API key."
  type        = string
}

variable "agent_plane_account_id" {
  description = <<-EOT
    Account holding the apply role Atlantis assumes. The role's ARN is
    constructed from this and `name_prefix` rather than taken as an output of
    the agent-plane module: each module would otherwise need the other's
    output, and neither could be applied first.

    Both modules must therefore be called with the same `name_prefix`. For a
    single-account deployment this is simply this account's own id, which
    collapses the authority boundary — acceptable for a trial, not for a client.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.agent_plane_account_id))
    error_message = "agent_plane_account_id must be a 12-digit AWS account id."
  }
}

# ---- Sizing ----

variable "atlantis_cpu" {
  description = "Fargate CPU units for Atlantis."
  type        = number
  default     = 1024
}

variable "atlantis_memory" {
  description = "Fargate memory (MiB) for Atlantis."
  type        = number
  default     = 2048
}

variable "agent_cpu" {
  description = "Fargate CPU units for one agent task."
  type        = number
  default     = 2048
}

variable "agent_memory" {
  description = "Fargate memory (MiB) for one agent task."
  type        = number
  default     = 4096
}

variable "log_retention_days" {
  description = "CloudWatch retention for both task families."
  type        = number
  default     = 30
}
