# A single-account trial: the smallest deployment that proves the gate refuses
# and admits for real, in real AWS.
#
# It collapses the two planes into one account, which gives up the authority
# boundary the design exists to create — an SCP, a budget, and a quota all
# attach to an account, so one account cannot bound itself. That is acceptable
# for a trial and is not a client deployment. The variables are identical in
# shape to the two-account form, so splitting later is a change of inputs
# rather than of code.
#
# What the trial proves, and all it proves:
#   a compliant plan applies, a violating plan is refused, and the refusal
#   names the rule.
#
# The fixture repository it acts on uses only the null, local, and random
# providers, so the infrastructure being applied costs nothing. The only spend
# is the Atlantis task and its storage.

data "aws_caller_identity" "current" {}

locals {
  tags = {
    "osf:deployment" = var.name_prefix
    "osf:purpose"    = "mvp-trial"
  }
}

module "control_plane" {
  source = "../../modules/control-plane"

  name_prefix = var.name_prefix
  tags        = local.tags

  # Let the module create the network, so the trial needs nothing from a
  # networking team. A client deployment injects subnets instead.
  network_mode = "create_vpc"
  vpc_cidr     = "10.60.0.0/16"

  broker_image = var.broker_image
  agent_image  = var.agent_image

  repo_allowlist           = var.repo_allowlist
  git_user                 = var.git_user
  git_token_secret_arn     = var.git_token_secret_arn
  model_api_key_secret_arn = var.model_api_key_secret_arn
  monthly_cost_ceiling_usd = var.monthly_cost_ceiling_usd

  # The same account, which is what makes this a trial rather than a
  # deployment. In the two-account form this is the agent account's id.
  agent_plane_account_id = data.aws_caller_identity.current.account_id

  # Deliberately narrow: the trial's fixture provisions nothing billable, so
  # the allowlist only needs the types its plans contain. An empty list would
  # refuse everything, which is the unconfigured default.
  policy_data = {
    allowed_resource_types = [
      "null_resource",
      "local_file",
      "random_pet",
    ]
    allowed_instance_families = []
    refuse_delete             = false
  }
}

module "agent_plane" {
  source = "../../modules/agent-plane"

  name_prefix = var.name_prefix
  tags        = local.tags

  control_plane_account_id = data.aws_caller_identity.current.account_id

  # The fixture applies null/local/random resources, which need no AWS
  # permission at all. The apply role therefore gets a deliberately useless
  # grant: the trial proves the gate, not the breadth of the applier.
  apply_permissions = ["sts:GetCallerIdentity"]
  allowed_regions   = [var.region]

  monthly_budget_usd = var.monthly_budget_usd
}
