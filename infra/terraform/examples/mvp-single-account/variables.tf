variable "region" {
  description = "Region for the trial."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource. Both modules must receive the same one."
  type        = string
  default     = "osf-mvp"
}

variable "broker_image" {
  description = "Broker image, pinned by digest. Built and pushed by the repository's CI."
  type        = string
}

variable "agent_image" {
  description = <<-EOT
    Harness image, pinned by digest. The MVP does not exercise the agent — the
    gate is driven directly over the Atlantis API — so any digest-pinned image
    satisfies this until the harness client exists.
  EOT
  type        = string
}

variable "repo_allowlist" {
  description = "Repositories Atlantis may act on, e.g. [\"github.com/eFactory-ai/osf-iac-trial\"]."
  type        = list(string)
}

variable "git_user" {
  description = "Git-forge user Atlantis clones and comments as."
  type        = string
}

variable "git_token_secret_arn" {
  description = "Secrets Manager ARN holding that user's token."
  type        = string
}

variable "model_api_key_secret_arn" {
  description = "Secrets Manager ARN holding the model API key. Unused by the MVP but required by the module."
  type        = string
}

variable "monthly_cost_ceiling_usd" {
  description = <<-EOT
    Ceiling the cost gate enforces. Left null for the trial: no estimator
    exists yet, and the gate denies by default, so a ceiling here would refuse
    every plan on cost and the trial could never demonstrate an apply.
  EOT
  type        = number
  default     = null
}

variable "monthly_budget_usd" {
  description = "Account budget. A lagging backstop, not the spend control."
  type        = number
  default     = 100
}
