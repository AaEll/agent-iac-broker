# The apply role: the only credential in the system able to mutate
# infrastructure. It lives here, in the agent plane, and only the control
# plane's applier may assume it.

data "aws_iam_policy_document" "apply_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.atlantis_task_role_arn]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.name_prefix}-apply"
  description          = "Assumed by the control-plane applier. Nothing else may assume it."
  assume_role_policy   = data.aws_iam_policy_document.apply_assume.json
  max_session_duration = 3600
  tags                 = local.tags
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ApplyWithinAllowedRegions"
    actions   = var.apply_permissions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }
  }

  # Reshaping the network the agent runs inside is a different act from
  # building within it. The rule sets refuse these at plan time; this denies
  # them at the API, so a gate bypass still cannot widen the cage.
  statement {
    sid    = "NeverReshapeTheNetwork"
    effect = "Deny"
    actions = [
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateVpcPeeringConnection",
      "ec2:AcceptVpcPeeringConnection",
      "ec2:CreateInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:CreateNatGateway",
      "ec2:CreateRoute",
      "ec2:ReplaceRoute",
      "ec2:CreateRouteTable",
      "ec2:AssociateRouteTable",
      "ec2:CreateNetworkAcl",
      "ec2:CreateNetworkAclEntry",
      "ec2:CreateVpcEndpoint",
      "ec2:CreateTransitGatewayVpcAttachment",
      "ec2:CreateVpnConnection",
      "ec2:CreateVpnGateway",
    ]
    resources = ["*"]
  }

  # Privilege escalation. An applier that can write IAM can grant itself
  # anything, so the identity surface is denied outright rather than bounded.
  statement {
    sid    = "NeverWriteIdentity"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreateLoginProfile",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePermissionsBoundary",
      "iam:CreatePolicyVersion",
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  # Its own role, the budget, the reaper, and the guardrails are not its to
  # edit. Without this an applier could raise its own ceiling.
  statement {
    sid    = "NeverEditItsOwnGuardrails"
    effect = "Deny"
    actions = [
      "iam:*",
      "budgets:ModifyBudget",
      "budgets:DeleteBudget",
      "servicequotas:*",
      "events:DeleteRule",
      "events:DisableRule",
      "events:RemoveTargets",
    ]
    resources = [
      aws_iam_role.apply.arn,
      "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/${var.name_prefix}-agent-plane",
      aws_cloudwatch_event_rule.reaper.arn,
    ]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

# ---- The agent's own read-only identity ----

data "aws_iam_policy_document" "agent_read_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.atlantis_task_role_arn]
    }
  }
}

# Read access is granted broadly and deliberately: an agent that cannot read
# the account it operates cannot debug what it deployed. This accepts that the
# agent can read data in this account, which is why client production data does
# not belong here.
resource "aws_iam_role" "agent_read" {
  name               = "${var.name_prefix}-agent-read"
  description        = "Read-only view of the agent plane. Mutates nothing."
  assume_role_policy = data.aws_iam_policy_document.agent_read_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "agent_read" {
  role       = aws_iam_role.agent_read.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
