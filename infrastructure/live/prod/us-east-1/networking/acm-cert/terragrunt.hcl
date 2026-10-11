# infrastructure/live/prod/us-east-1/networking/acm-cert/terragrunt.hcl
#
# Public ACM cert (apex + wildcard), DNS-validated against the account-global
# Route53 zone. Standalone/decoupled from eks so a cert-in-use failure at teardown
# (LB still deprovisioning) can't early-exit the vpc destroy and leak the VPC.
# No dependencies: it only data-reads the global zone. Consumed by kubernetes/argocd.

# The DNS validation CNAME is owned by global/networking/acm-validation, not
# here (core-platform-infra#80; manage_validation_records defaults to false):
# tearing this env down no longer deletes the record other certs renew with.
# That global unit must be applied first, or this validation waits.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../modules/acm-cert"
}

# domain_name defaults to core-platform.click (the account-global zone).
