# The caller's principal, so the account ID stays out of the code.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  service_cidr = "10.100.0.0/16"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = "martin-project-final"
  kubernetes_version = "1.37"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  create_kms_key             = false
  encryption_config          = null
  enable_irsa                = false
  create_node_security_group = false
  service_ipv4_cidr          = local.service_cidr

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  enable_cluster_creator_admin_permissions = false
  access_entries = {
    martin = {
      principal_arn = data.aws_iam_session_context.current.issuer_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    aws-secrets-store-csi-driver-provider = {
      # Pinned: unpinned, the module takes the newest build and later plans drift.
      addon_version = "v3.1.4-eksbuild.4"
      configuration_values = jsonencode({
        "secrets-store-csi-driver" = { enableSecretRotation = true }
      })
    }
  }
}
