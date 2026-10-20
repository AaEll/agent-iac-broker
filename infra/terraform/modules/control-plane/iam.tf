# Three identities, and the distance between them is the design.
#
# The execution role pulls images and writes logs. The Atlantis task role is
# the only one that can reach the credential able to mutate infrastructure, and
# it reaches it by assuming a role in the other account. The agent task role
# can read a secret, write an outcome, and reach nothing else: it cannot apply,
# and it cannot assume the apply role.

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The execution role reads the secrets ECS injects as environment variables.
# Scoped to the three named ARNs, never a wildcard.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.git_token_secret_arn,
      var.model_api_key_secret_arn,
      aws_secretsmanager_secret.atlantis_api.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ---- Atlantis ----

resource "aws_iam_role" "atlantis" {
  name               = "${var.name_prefix}-atlantis"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "atlantis" {
  # The apply credential. Atlantis holds it by assuming a role in the agent
  # account; nothing in this account can mutate the agent plane directly.
  statement {
    sid       = "AssumeApplyRoleInAgentPlane"
    actions   = ["sts:AssumeRole"]
    resources = [local.agent_plane_apply_role_arn]
  }

  # Remote state for the plans it applies.
  statement {
    sid       = "TerraformStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "TerraformStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "TerraformStateLock"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.state_lock.arn]
  }
}

resource "aws_iam_role_policy" "atlantis" {
  name   = "apply"
  role   = aws_iam_role.atlantis.id
  policy = data.aws_iam_policy_document.atlantis.json
}

# ---- The agent ----

resource "aws_iam_role" "agent" {
  name               = "${var.name_prefix}-agent"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "agent" {
  # The outcome record: write its own, read its own. Conditional writes are how
  # idempotency holds, so PutItem is required and DeleteItem is not granted.
  statement {
    sid       = "OutcomeRecord"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.outcomes.arn]
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "outcomes"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

# Stated as an explicit deny rather than relied on by omission: the agent task
# must never hold a path to the apply credential, and a future policy addition
# that granted sts:AssumeRole broadly would otherwise open one silently.
data "aws_iam_policy_document" "agent_denies_apply" {
  statement {
    sid       = "NeverAssumeTheApplyRole"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = [local.agent_plane_apply_role_arn]
  }
}

resource "aws_iam_role_policy" "agent_denies_apply" {
  name   = "deny-apply"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_denies_apply.json
}
