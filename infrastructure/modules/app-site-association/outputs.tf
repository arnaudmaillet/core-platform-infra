# infrastructure/modules/app-site-association/outputs.tf

output "aasa_url" {
  description = "Where Apple fetches the file."
  value       = "https://${var.domain_name}/.well-known/apple-app-site-association"
}

output "aasa_json" {
  description = "The served apple-app-site-association document."
  value       = local.aasa
}

output "distribution_id" {
  description = "CloudFront distribution id (invalidate /.well-known/* after a content change if you can't wait for the 5-minute TTL)."
  value       = aws_cloudfront_distribution.site.id
}
