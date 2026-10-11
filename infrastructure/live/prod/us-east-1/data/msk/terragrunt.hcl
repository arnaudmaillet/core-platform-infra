# infrastructure/live/prod/us-east-1/data/msk/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "vpc" {
  config_path = "../../networking/vpc"

  # Plan/validate mocks let `run-all plan` cover this unit before the VPC exists
  # (first bring-up, or after a teardown); destroy, because a partial teardown can
  # leave the vpc unit without outputs and brick this unit's destroy. Terragrunt
  # only uses them when the vpc unit has no outputs; apply always needs the real
  # VPC. Shaped like the real outputs (3 AZs, the env.hcl CIDR).
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    vpc_id                  = "vpc-00000000000000000"
    private_data_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001", "subnet-00000000000000002"]
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
  # 3 brokers across the 3 data-subnet AZs — the durable-Kafka floor: RF 3 with
  # min.insync.replicas 2 (module defaults) survives one broker/AZ down while
  # acks=all still commits.
  number_of_broker_nodes = 3
  broker_instance_type   = "kafka.m5.large" # t3.small burst credits are not a prod posture
  broker_ebs_volume_size = 100
  allowed_cidr_blocks    = [dependency.vpc.outputs.vpc_cidr_block]

  # RF 3 / min.insync 2 come from the module defaults. Keep the prod overlay's
  # topic-provisioner Job TOPIC_REPLICATION_FACTOR=3 in lockstep.

  tags = {
    Environment = local.env_vars.locals.env
    ManagedBy   = "terragrunt"
  }
}
