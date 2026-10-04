# infrastructure/live/global/messaging/ses-identity/terragrunt.hcl
#
# Account-global Amazon SES domain identity (core-platform.click): Easy DKIM,
# custom MAIL FROM (mail.core-platform.click), SPF, DMARC and the account
# suppression list (guest-mode B4b, core-platform-infra#13). Lives in `global/`
# because an SES identity, like the Route53 zone it writes into, is account +
# region scoped: every env sends through it with its own IAM SMTP user
# (data/app-secrets). Reads the zone by name (no dependency edge), so
# global/networking/route53 must exist first.
#
# One-time manual step, NOT in Terraform: request SES production access (leave
# the sandbox) before real users sign up; see docs/runbooks/environment-lifecycle.md.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  # 4 levels up reaches infrastructure/ (live/global/messaging/ses-identity).
  source = "../../../../modules/ses-identity"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  domain_name = local.env_vars.locals.domain_name

  tags = {
    ManagedBy = "terragrunt"
  }
}
