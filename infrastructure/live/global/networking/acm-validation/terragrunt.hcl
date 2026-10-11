# infrastructure/live/global/networking/acm-validation/terragrunt.hcl
#
# The SINGLE owner of the ACM DNS validation CNAME of core-platform.click
# (core-platform-infra#80). ACM uses the same `_<hash>.<domain>` record for every
# certificate of this account on a domain, apex and wildcard alike. When each
# cert unit owned it, a staging teardown deleted it, and every other cert (prod,
# the global AASA) could no longer auto-renew. Now:
#   * this unit (manage_validation_records = true) creates and keeps it; it is
#     account-global, never torn down with an env;
#   * every other ACM unit (networking/acm-cert per env, web/app-site-association)
#     only waits on it.
# The apex + wildcard cert it requests is a by-product (ACM certs are free); it is
# also a valid account-level cert. Apply it before any env's networking/acm-cert.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  # 4 levels up reaches infrastructure/ (live/global/networking/acm-validation).
  source = "../../../../modules/acm-cert"
}

# Ordering only (the zone is read by name).
dependency "zone" {
  config_path  = "../route53"
  skip_outputs = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  domain_name               = local.env_vars.locals.domain_name
  manage_validation_records = true
}
