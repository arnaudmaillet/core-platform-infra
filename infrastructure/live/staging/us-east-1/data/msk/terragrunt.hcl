# infrastructure/live/staging/us-east-1/data/msk/terragrunt.hcl

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
  source = "../../../../../modules/msk"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  name       = "core-platform-${local.env_vars.locals.env}"
  vpc_id     = dependency.vpc.outputs.vpc_id
  subnet_ids = dependency.vpc.outputs.private_data_subnet_ids
  # Broker count MUST be a multiple of the AZ/subnet count. Staging's VPC has 2
  # data-subnet AZs, so 2 brokers (the module default is 3, which would fail to
  # provision here). C7.
  number_of_broker_nodes = 2
  allowed_cidr_blocks    = [dependency.vpc.outputs.vpc_cidr_block]

  # 2 brokers => RF is capped at 2, and min.insync must stay 1 or a single
  # broker outage stops all producing. PROD (3 AZ / 3 brokers) => omit both
  # (module defaults: RF 3 / min.insync 2). Keep TOPIC_REPLICATION_FACTOR on
  # the topic-provisioner Job in lockstep with this RF.
  default_replication_factor = 2
  min_insync_replicas        = 1
  # Staging cost: 10 GiB per broker (module default 50) is plenty for test
  # traffic at the registry's retentions. PROD => omit.
  broker_ebs_volume_size = 10

  # Disposable staging: drop the secret immediately on destroy so a rebuild
  # doesn't collide with the SCRAM secret name's recovery window. PROD => omit
  # (defaults to the recoverable AWS window).
  secret_recovery_window_days = 0

  tags = {
    Environment = local.env_vars.locals.env
    ManagedBy   = "terragrunt"
  }
}
