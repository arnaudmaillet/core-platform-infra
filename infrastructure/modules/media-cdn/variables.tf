# infrastructure/modules/media-cdn/variables.tf

variable "name" {
  type        = string
  description = "Env-scoped prefix, e.g. core-platform-staging. Names the distribution's OAC and cache policy."
}

variable "bucket_name" {
  type        = string
  description = "The media bucket (data/media-bucket). Its bucket policy is OWNED by this module: it grants the distribution's OAC read access."
}

variable "bucket_arn" {
  type        = string
  description = "ARN of the media bucket."
}

variable "bucket_regional_domain_name" {
  type        = string
  description = "Regional domain of the media bucket (the CloudFront S3 origin)."
}

variable "domain_name" {
  type        = string
  description = "Alias the media URLs use (MEDIA_CDN_BASE_URL), e.g. media.core-platform.click. Must be covered by certificate_arn and live in zone_name."
}

variable "zone_name" {
  type        = string
  description = "Public Route53 zone the alias records go into."
  default     = "core-platform.click"
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate covering domain_name, in us-east-1 (a CloudFront requirement); the env's networking/acm-cert wildcard."
}

variable "private_prefixes" {
  type        = list(string)
  description = "Key prefixes the CDN must NEVER serve (explicit Deny for the distribution, whatever the key): takedowns (quarantine/), original uploads (uploads/) and verification documents (private/)."
  default     = ["quarantine/", "uploads/", "private/"]
}

variable "price_class" {
  type        = string
  description = "CloudFront price class: PriceClass_All (every edge, the app is worldwide) or PriceClass_100/200 (cheaper, fewer edges)."
  default     = "PriceClass_All"
}

variable "media_iam_user_name" {
  type        = string
  description = "The media static-key IAM user (data/app-secrets <name>-media-s3). Gets cloudfront:CreateInvalidation on this distribution, for takedown purges."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
