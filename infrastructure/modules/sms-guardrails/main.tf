# infrastructure/modules/sms-guardrails/main.tf
#
# Account-level guardrails for SMS sent through Amazon SNS: auth's one-time codes
# for phone-only accounts (guest-mode B4c, core-platform-infra#14; backend
# core-platform-backend#719). Every SMS costs money, so the threat is SMS pumping /
# toll fraud: an attacker sprays StartVerification across premium-rate numbers.
# Per-number caps (auth) and per-IP caps (the `verification` edge profile) don't
# stop that alone; this adds the account-wide brakes:
#
#   * SMS preferences: MonthlySpendLimit (hard stop) + Transactional by default.
#   * Alarms on the month-to-date spend (% of the limit) and on an hourly spike,
#     to an ops-alerts SNS topic (email from an SSM parameter, out of git).
#   * A country allow-list: an AWS End User Messaging SMS protect configuration,
#     set as the ACCOUNT DEFAULT (the only way it applies to SNS), BLOCKing every
#     destination outside `allowed_countries` (scripts/sms-protect.sh, local-exec:
#     the provider has no resource for it, so the applier needs the AWS CLI v2).
#   * Delivery-status logging to CloudWatch Logs (optional, enable_delivery_status_logs:
#     the applier then needs iam:PassRole on the role).
#
# ACCOUNT + REGION scoped, so this lives in `live/global`. The per-env sender (an
# IAM user allowed to publish to phone numbers only) is in modules/app-secrets.
#
# NOT Terraform-manageable (one-time, per account + region, see
# docs/runbooks/environment-lifecycle.md): leaving the SNS SMS SANDBOX (until then
# SNS only texts verified numbers) and raising the SMS spending quota above 1 USD.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── Delivery-status logging ───────────────────────────────────────────────────
# SNS writes to these two log groups; creating them here sets their retention.
locals {
  sms_log_prefix = "sns/${data.aws_region.current.region}/${data.aws_caller_identity.current.account_id}/DirectPublishToPhoneNumber"
}

resource "aws_cloudwatch_log_group" "sms_delivery" {
  for_each          = var.enable_delivery_status_logs ? toset([local.sms_log_prefix, "${local.sms_log_prefix}/Failure"]) : toset([])
  name              = each.value
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "sms_delivery_status" {
  count = var.enable_delivery_status_logs ? 1 : 0
  name  = "${var.name}-sns-sms-delivery-status"
  tags  = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "sms_delivery_status" {
  count = var.enable_delivery_status_logs ? 1 : 0
  name  = "cloudwatch-logs"
  role  = aws_iam_role.sms_delivery_status[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:PutMetricFilter", "logs:PutRetentionPolicy"]
      Resource = [for g in aws_cloudwatch_log_group.sms_delivery : "${g.arn}:*"]
    }]
  })
}

# ── SMS preferences (account-level) ───────────────────────────────────────────
resource "aws_sns_sms_preferences" "this" {
  monthly_spend_limit                   = var.monthly_spend_limit_usd
  default_sms_type                      = "Transactional"
  delivery_status_iam_role_arn          = var.enable_delivery_status_logs ? aws_iam_role.sms_delivery_status[0].arn : null
  delivery_status_success_sampling_rate = var.enable_delivery_status_logs ? tostring(var.delivery_status_success_sampling_pct) : null
}

# ── Alarms ────────────────────────────────────────────────────────────────────
data "aws_ssm_parameters_by_path" "ops" {
  path = dirname(var.alert_email_ssm_parameter)
}

locals {
  # Tolerant lookup: an absent parameter yields "" (no subscription) rather than
  # failing the plan, unlike data "aws_ssm_parameter".
  alert_email = try(
    data.aws_ssm_parameters_by_path.ops.values[index(data.aws_ssm_parameters_by_path.ops.names, var.alert_email_ssm_parameter)],
    "",
  )
}

resource "aws_sns_topic" "ops_alerts" {
  name = "${var.name}-ops-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "ops_alerts_email" {
  count     = local.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = local.alert_email
}

resource "aws_cloudwatch_metric_alarm" "sms_spend" {
  for_each = toset([for p in var.spend_alarm_thresholds_pct : tostring(p)])

  alarm_name          = "${var.name}-sms-spend-${each.value}pct"
  alarm_description   = "SNS SMS month-to-date spend reached ${each.value}% of the ${var.monthly_spend_limit_usd} USD monthly limit (SNS stops sending at 100%). Check for SMS pumping (auth logs; the delivery-status logs show destinations when enabled)."
  namespace           = "AWS/SNS"
  metric_name         = "SMSMonthToDateSpentUSD"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.monthly_spend_limit_usd * tonumber(each.value) / 100
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "sms_spend_spike" {
  alarm_name          = "${var.name}-sms-spend-spike"
  alarm_description   = "SNS SMS spend grew by more than ${var.spend_spike_usd_per_hour} USD within an hour: likely SMS pumping. Check auth's StartVerification traffic (and the delivery-status logs when enabled)."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.spend_spike_usd_per_hour
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
  tags                = var.tags

  metric_query {
    id = "spend"
    metric {
      namespace   = "AWS/SNS"
      metric_name = "SMSMonthToDateSpentUSD"
      period      = 3600
      stat        = "Maximum"
    }
  }

  # Hour-over-hour growth of the month-to-date total (negative at the monthly reset).
  metric_query {
    id          = "growth"
    expression  = "DIFF(spend)"
    label       = "SMS spend growth per hour (USD)"
    return_data = true
  }
}

# ── Country allow-list (protect configuration, account default) ──────────────
resource "terraform_data" "sms_protect" {
  triggers_replace = {
    region    = data.aws_region.current.region
    countries = join(",", sort(var.allowed_countries))
  }

  provisioner "local-exec" {
    command = join(" ", concat(
      ["bash", "${path.module}/scripts/sms-protect.sh", data.aws_region.current.region, "${var.name}-sms-protect"],
      sort(var.allowed_countries),
    ))
  }
}
