# infrastructure/live/staging/us-east-1/networking/media-cdn/terragrunt.hcl
#
# CloudFront (OAC) in front of the media bucket, alias media-staging.core-platform.click
# (guest-mode B6, core-platform-infra#25). Owns the media bucket's policy (CDN
# read, never quarantine/ uploads/ private/) and grants the media IAM user the
# takedown purge. Its distribution id reaches media through the envsubst CMP
# (MEDIA_CLOUDFRONT_DISTRIBUTION_ID, kubernetes/argocd), so this unit applies
# before argocd. The env's wildcard ACM cert (us-east-1) covers the alias.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../modules/media-cdn"
}

dependency "media_bucket" {
  config_path = "../../data/media-bucket"
  mock_outputs = {
    bucket_name                 = "mock-media"
    bucket_arn                  = "arn:aws:s3:::mock-media"
    bucket_regional_domain_name = "mock-media.s3.us-east-1.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "acm_cert" {
  config_path                             = "../acm-cert"
  mock_outputs                            = { certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Ordering-only: the media IAM user (<name>-media-s3) must exist before this unit
# attaches the invalidation policy to it.
dependency "app_secrets" {
  config_path  = "../../data/app-secrets"
  skip_outputs = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  name                        = "core-platform-${local.env_vars.locals.env}"
  bucket_name                 = dependency.media_bucket.outputs.bucket_name
  bucket_arn                  = dependency.media_bucket.outputs.bucket_arn
  bucket_regional_domain_name = dependency.media_bucket.outputs.bucket_regional_domain_name
  certificate_arn             = dependency.acm_cert.outputs.certificate_arn

  # MEDIA_CDN_BASE_URL in k8s/overlays/staging/media.env must match.
  domain_name = "media-staging.core-platform.click"
  # Staging: North America + Europe edges only (cheaper, test traffic).
  price_class = "PriceClass_100"

  media_iam_user_name = "core-platform-${local.env_vars.locals.env}-media-s3"

  tags = {
    Environment = local.env_vars.locals.env
    ManagedBy   = "terragrunt"
    Service     = "media"
  }
}
