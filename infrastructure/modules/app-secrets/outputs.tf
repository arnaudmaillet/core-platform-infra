# infrastructure/modules/app-secrets/outputs.tf

output "media_s3_secret_arn" {
  description = "ARN of the media static-key secret."
  value       = aws_secretsmanager_secret.media_s3.arn
}

output "scylla_s3_secret_arn" {
  description = "ARN of the scylla-manager-agent backup static-key secret."
  value       = aws_secretsmanager_secret.scylla_s3.arn
}

output "audit_crypto_secret_arn" {
  description = "ARN of the audit crypto/custody secret."
  value       = aws_secretsmanager_secret.audit_crypto.arn
}

output "auth_smtp_secret_arn" {
  description = "ARN of the auth SES SMTP credentials secret."
  value       = aws_secretsmanager_secret.auth_smtp.arn
}

output "auth_sns_secret_arn" {
  description = "ARN of the auth SNS (SMS) static-key secret."
  value       = aws_secretsmanager_secret.auth_sns.arn
}

output "auth_mfa_secret_id" {
  description = "Id (ARN) of the auth MFA seed key secret."
  value       = local.auth_mfa_secret_id
}

output "account_exports_secret_arn" {
  description = "ARN of the account GDPR-export static-key secret."
  value       = aws_secretsmanager_secret.account_exports.arn
}

output "auth_secrets_secret_arn" {
  description = "ARN of the auth signing/Keycloak secret."
  value       = aws_secretsmanager_secret.auth_secrets.arn
}
