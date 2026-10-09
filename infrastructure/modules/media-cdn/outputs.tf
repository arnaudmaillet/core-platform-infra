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
