# infrastructure/modules/sms-guardrails/outputs.tf

output "alerts_topic_arn" {
  description = "SNS topic the SMS spend alarms publish to (ops alerts)."
  value       = aws_sns_topic.ops_alerts.arn
}

output "alert_email_subscribed" {
  description = "Whether an email subscription was created from the SSM parameter (it must then be confirmed from the inbox)."
  # The SSM parameter values are sensitive; whether one was found is not.
  value = nonsensitive(local.alert_email != "")
}

output "allowed_countries" {
  description = "Countries the account-default protect configuration allows for SMS."
  value       = sort(var.allowed_countries)
}
