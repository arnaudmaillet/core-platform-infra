# infrastructure/live/prod/us-east-1/data/gdpr-exports/terragrunt.hcl
#
# Private bucket for the GDPR data exports (Art. 15/20, core-platform-infra#28):
# account-server's export pass writes one ZIP per request under exports/ and
# records a SigV4 presigned link valid 7 days. Objects expire after 8 days.
# Personal data: public access blocked (module default), SSE-S3, no versioning,
# never log the presigned URLs. Written by the static-key IAM user
# <name>-account-exports (data/app-secrets).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../modules/s3-bucket"
}

locals {
  env_vars   = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  account_id = get_aws_account_id()
}

inputs = {
  # Account id suffix for global uniqueness, like the media bucket. Must match
  # ACCOUNT_EXPORT_BUCKET in k8s/overlays/prod/account.env.
  name               = "core-platform-${local.env_vars.locals.env}-gdpr-exports-${local.account_id}"
  versioning_enabled = false
  # Links live 7 days; one more day of margin.
  expiration_days = 8
  # Prod exports hold personal data until they expire; destroy must never
  # empty the bucket silently.
  force_destroy = false

  tags = {
    Environment = local.env_vars.locals.env
    ManagedBy   = "terragrunt"
    Service     = "account"
  }
}
