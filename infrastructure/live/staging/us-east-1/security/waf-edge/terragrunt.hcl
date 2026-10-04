# infrastructure/live/staging/us-east-1/security/waf-edge/terragrunt.hcl
#
# AWS WAF Web ACL for the client-edge ALB (guest-mode B5, core-platform-infra#11).
# No dependencies: the ALB is owned by the AWS Load Balancer Controller, which
# associates the ACL from the Ingress annotation. The ARN reaches the Ingress via
# the kubernetes/argocd unit (envsubst CMP value WAF_EDGE_ACL_ARN), so this unit
# applies before it.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../modules/waf-edge"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  name = "core-platform-${local.env_vars.locals.env}"

  # Module defaults (owner's choice: rate-based + baseline managed rules):
  #   rate_limit_per_ip             = 2000  # per 5 min, wide for mobile CGNAT
  #   guest_start_rate_limit_per_ip = 100   # per 5 min on StartGuestSession
  #   common_rule_set_mode          = "count"  # flip to "block" once sampled requests are clean
  #   enable_bot_control            = false

  tags = {
    Environment = local.env_vars.locals.env
    ManagedBy   = "terragrunt"
  }
}
