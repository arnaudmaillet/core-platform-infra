# infrastructure/modules/ses-identity/outputs.tf

output "identity_arn" {
  description = "ARN of the SES domain identity. The per-env SMTP users (data/app-secrets) may only send through it."
  value       = aws_sesv2_email_identity.domain.arn
}

output "domain_name" {
  description = "The verified sending domain."
  value       = aws_sesv2_email_identity.domain.email_identity
}

output "mail_from_domain" {
  description = "The custom MAIL FROM domain."
  value       = aws_sesv2_email_identity_mail_from_attributes.domain.mail_from_domain
}
