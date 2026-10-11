# infrastructure/live/dev/us-east-1/kubernetes/00-identity/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "eks" {
  config_path = "../../eks"

  # Plan/validate mocks let `run-all plan` cover this unit before the cluster
  # exists. Destroy, because after a partial teardown the eks unit's outputs are
  # gone from state and this unit's destroy dies at HCL evaluation ("no variable
  # named dependency"), as seen live on the 2026-07-04 staging teardown. The
  # mock cluster_name is the real one, so the planned role names are accurate.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    cluster_name       = "core-platform-dev"
    oidc_provider_arn  = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/MOCK"
    oidc_provider_url  = "oidc.eks.us-east-1.amazonaws.com/id/MOCK"
    node_iam_role_arns = ["arn:aws:iam::000000000000:role/mock"]
  }
}

terraform {
  source = "../../../../../modules//security/irsa-roles"
}

inputs = {
  cluster_name      = dependency.eks.outputs.cluster_name
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
  oidc_provider_url = dependency.eks.outputs.oidc_provider_url


  # Crucial pour Karpenter : on lui dit quels rôles de nodes il a le droit d'utiliser
  node_iam_role_arns = dependency.eks.outputs.node_iam_role_arns

  # Centralisation de la policy JSON (standard SRE)
  iam_policy_json_content = file("${get_repo_root()}/infrastructure/assets/iam-policies/aws-lb-controller.json")

  tags = {
    Environment = "dev"
    ManagedBy   = "terragrunt"
  }
}