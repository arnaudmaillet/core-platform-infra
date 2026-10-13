# infrastructure/modules/media-cdn/outputs.tf

output "distribution_id" {
  description = "CloudFront distribution id: MEDIA_CLOUDFRONT_DISTRIBUTION_ID (takedown purges), fed to the envsubst CMP."
  value       = aws_cloudfront_distribution.media.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.media.arn
}

output "base_url" {
  description = "MEDIA_CDN_BASE_URL: https://<alias>."
  value       = "https://${var.domain_name}"
}

output "cookie_key_pair_id" {
  description = "CloudFront public key id media signs cookies with (MEDIA_CDN_COOKIE_KEY_PAIR_ID, also in the cookie secret)."
  value       = aws_cloudfront_public_key.cookie.id
}

output "cookie_secret_name" {
  description = "Secrets Manager secret holding media's cookie key (key_pair_id, private_key), read by the media-cdn-cookie ExternalSecret."
  value       = aws_secretsmanager_secret.cookie.name
}
