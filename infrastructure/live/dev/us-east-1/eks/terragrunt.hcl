# infrastructure/live/dev/us-east-1/eks/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
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

terraform {
  source = "../../../../modules/eks"

  # # --- NETTOYAGE PRÉ-DESTROY ---
  # # On s'assure que les ressources critiques (Ingress/ALB) sont parties
  # # AVANT que Terraform ne commence à supprimer les Nodes EKS.
  # before_hook "k8s_cleanup" {
  #   commands     = ["destroy"]
  #   # On supprime tous les ingress. Le --wait=true est vital ici.
  #   # On ajoute || true pour ne pas bloquer le destroy si le cluster est déjà partiellement cassé.
  #   execute      = ["/bin/bash", "-c", "kubectl delete ingress --all --all-namespaces --timeout=5m || true"]
  # }

  # after_hook "cleanup_check" {
  #   commands     = ["destroy"]
  #   execute      = ["/bin/bash", "-c", "echo 'Vérification finale des ressources orphelines...'; sleep 5"]
  #   run_on_error = false
  # }
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  cluster_name       = "core-platform-${local.env_vars.locals.env}"
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_app_subnet_ids
  vpc_cidr           = dependency.vpc.outputs.vpc_cidr_block

  # Tighten the public API endpoint to your admin/CI ranges when ready, e.g.:
  # endpoint_public_access_cidrs = ["203.0.113.4/32"]

  # Injecte la map dynamique définie dans env.hcl (Node Groups système)
  node_groups = local.env_vars.locals.node_groups

  project_name = "core-platform"
  env          = local.env_vars.locals.env
}