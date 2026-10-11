# infrastructure/live/staging/us-east-1/data/elasticache/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "vpc" {
  config_path = "../../networking/vpc"

  # Plan/validate mocks let `run-all plan` cover this unit before the VPC exists
  # (first bring-up, or after a teardown); destroy, because a partial teardown can
  # leave the vpc unit without outputs and brick this unit's destroy. Terragrunt
  # only uses them when the vpc unit has no outputs; apply always needs the real
  # VPC. Shaped like the real outputs (2 AZs, the env.hcl CIDR).
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    vpc_id                  = "vpc-00000000000000000"
    private_data_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001"]
    vpc_cidr_block          = local.env_vars.locals.vpc_cidr
  }
}

terraform {
  source = "../../../../../modules/elasticache"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  name                = "core-platform-${local.env_vars.locals.env}"
  vpc_id              = dependency.vpc.outputs.vpc_id
  subnet_ids          = dependency.vpc.outputs.private_data_subnet_ids
  allowed_cidr_blocks = [dependency.vpc.outputs.vpc_cidr_block]

  # Disposable staging: drop the Redis-auth secret immediately on destroy so a
  # rebuild doesn't collide with its recovery window. PROD => omit (recoverable).
  secret_recovery_window_days = 0

  tags = {
    Environment = local.env_vars.locals.env
    ManagedBy   = "terragrunt"
  }
}
