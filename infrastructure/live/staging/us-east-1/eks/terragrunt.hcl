# infrastructure/live/staging/us-east-1/eks/terragrunt.hcl
# Mirrors the dev EKS component with staging's node_groups (env.hcl).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../modules/eks"
}

dependency "vpc" {
  config_path = "../networking/vpc"

  # Plan/validate mocks let `run-all plan` cover this unit before the VPC exists
  # (first bring-up, or after a teardown); destroy, because a partial teardown can
  # leave the vpc unit without outputs and brick this unit's destroy. Terragrunt
  # only uses them when the vpc unit has no outputs; apply always needs the real
  # VPC. Shaped like the real outputs (2 AZs, the env.hcl CIDR).
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    vpc_id                 = "vpc-00000000000000000"
    private_app_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001"]
    vpc_cidr_block         = local.env_vars.locals.vpc_cidr
  }
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  cluster_name       = "core-platform-${local.env_vars.locals.env}"
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_app_subnet_ids
  vpc_cidr           = dependency.vpc.outputs.vpc_cidr_block
  node_groups        = local.env_vars.locals.node_groups

  # Disposable env: never pay EKS extended support. AWS auto-upgrades the
  # control plane at end of standard support instead (see modules/eks).
  cluster_support_type = "STANDARD"

  # Staging cost: no control-plane logs in CloudWatch (audit alone was the
  # bulk of the log bill). Debug with kubectl / the pods' own logs. PROD keeps
  # the module default (api, audit, authenticator).
  cluster_enabled_log_types = []

  # Tighten the public API endpoint to your admin/CI ranges when ready, e.g.:
  # endpoint_public_access_cidrs = ["203.0.113.4/32"]

  project_name = "core-platform"
  env          = local.env_vars.locals.env
}
