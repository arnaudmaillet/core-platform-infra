# infrastructure/live/prod/us-east-1/eks/terragrunt.hcl
# Prod EKS: Graviton node groups from env.hcl (tainted database group, min 3/AZ-spread).

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
  # VPC. Shaped like the real outputs (3 AZs, the env.hcl CIDR).
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    vpc_id                 = "vpc-00000000000000000"
    private_app_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001", "subnet-00000000000000002"]
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

  # Locks the public EKS API to the admin/CI ranges in env.hcl. This is NOT the
  # module default (0.0.0.0/0) — prod must never expose the API to the world.
  # env.hcl ships a REPLACE.ME placeholder that fails the apply on purpose until
  # you set real CIDRs (fail-closed beats fail-open for prod).
  endpoint_public_access_cidrs = local.env_vars.locals.admin_cidrs

  project_name = "core-platform"
  env          = local.env_vars.locals.env
}
