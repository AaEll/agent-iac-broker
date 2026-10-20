locals {
  # Constructed, not referenced: see control_plane_account_id.
  atlantis_task_role_arn = "arn:aws:iam::${var.control_plane_account_id}:role/${var.name_prefix}-atlantis"

  tags = merge(var.tags, {
    "osf:component"  = "agent-plane"
    "osf:managed-by" = "terraform"
  })
}

data "aws_caller_identity" "current" {}

# The budget. Explicitly a backstop: it reacts to billed cost, so it bounds an
# overrun rather than preventing one.
resource "aws_budgets_budget" "account" {
  name         = "${var.name_prefix}-agent-plane"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [80, 100] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  tags = local.tags
}

# The reaper. Every applied resource carries the run id, and expiry destroys
# them unconditionally. Driven by wall clock, which is what makes it prompt
# where a budget action is not.
resource "aws_cloudwatch_event_rule" "reaper" {
  name                = "${var.name_prefix}-lease-reaper"
  description         = "Sweeps run-tagged resources past their lease TTL (${var.lease_ttl_hours}h)."
  schedule_expression = "rate(1 hour)"
  tags                = local.tags
}
