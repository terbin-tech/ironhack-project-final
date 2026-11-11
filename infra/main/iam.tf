data "aws_route53_zone" "diogo_world" {
  name         = "diogo.world"
  private_zone = false
}

locals {
  hosted_zone_id = data.aws_route53_zone.diogo_world.zone_id
  dns_names = [
    "martin.diogo.world",
    "a-martin.diogo.world",
    "aaaa-martin.diogo.world",
  ]

  # Immutable subjects (owner and repository IDs). A job that references an
  # environment gets the environment's subject instead of the branch's.
  github_repo    = "repo:terbin-tech@342395647/ironhack-project-final@1455597885"
  github_subject = { build = "${local.github_repo}:ref:refs/heads/main", record = "${local.github_repo}:environment:production" }
}

locals {
  docdb_master_secret_arn = aws_docdb_cluster.this.master_user_secret[0].secret_arn

  expensy_pod_secrets = {
    backend        = [aws_secretsmanager_secret.docdb_app.arn, aws_secretsmanager_secret.valkey["expensy"].arn]
    docdb-user-job = [local.docdb_master_secret_arn, aws_secretsmanager_secret.docdb_app.arn]
  }
  expensy_pod_role_names = {
    backend        = "martin-project-final-backend"
    docdb-user-job = "martin-project-final-docdb-user"
  }
}

data "aws_iam_policy_document" "expensy_pod_trust" {
  for_each = local.expensy_pod_secrets

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["expensy"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.key]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    # Confused-deputy guard; $${...} is the IAM policy variable, not Terraform's.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgId"
      values   = ["$${aws:ResourceOrgId}"]
    }
  }
}

data "aws_iam_policy_document" "expensy_pod" {
  for_each = local.expensy_pod_secrets

  statement {
    # No kms:Decrypt: the secrets use aws/secretsmanager, whose key policy
    # allows use through Secrets Manager.
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = each.value
  }
}

resource "aws_iam_role" "expensy_pod" {
  for_each = local.expensy_pod_secrets

  name               = local.expensy_pod_role_names[each.key]
  assume_role_policy = data.aws_iam_policy_document.expensy_pod_trust[each.key].json
}

resource "aws_iam_role_policy" "expensy_pod" {
  for_each = local.expensy_pod_secrets

  name   = "secrets"
  role   = aws_iam_role.expensy_pod[each.key].id
  policy = data.aws_iam_policy_document.expensy_pod[each.key].json
}

resource "aws_eks_pod_identity_association" "expensy" {
  for_each = local.expensy_pod_secrets

  cluster_name    = module.eks.cluster_name
  namespace       = "expensy"
  service_account = each.key
  role_arn        = aws_iam_role.expensy_pod[each.key].arn
}

data "aws_iam_policy_document" "external_dns_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgId"
      values   = ["$${aws:ResourceOrgId}"]
    }
  }
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${local.hosted_zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = local.dns_names
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A", "AAAA", "TXT"]
    }
  }

  statement {
    actions   = ["route53:ListResourceRecordSets", "route53:ListTagsForResources"]
    resources = ["arn:aws:route53:::hostedzone/${local.hosted_zone_id}"]
  }

  statement {
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "martin-project-final-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_trust.json
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53-records"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

# The OIDC provider is shared with other projects, so it is only read.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.github_subject

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

data "aws_iam_policy_document" "github_build" {
  statement {
    # GetAuthorizationToken does not support resource-level permissions.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [for repository in aws_ecr_repository.this : repository.arn]
  }
}

data "aws_iam_policy_document" "github_record" {
  statement {
    actions   = ["ecr:DescribeImages"]
    resources = [for repository in aws_ecr_repository.this : repository.arn]
  }
}

locals {
  github_policies = {
    build  = data.aws_iam_policy_document.github_build.json
    record = data.aws_iam_policy_document.github_record.json
  }
}

resource "aws_iam_role" "github" {
  for_each = local.github_subject

  name               = "martin-project-final-github-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.github_trust[each.key].json
}

resource "aws_iam_role_policy" "github" {
  for_each = local.github_subject

  name   = "ecr"
  role   = aws_iam_role.github[each.key].id
  policy = local.github_policies[each.key]
}

data "aws_iam_policy_document" "cloudwatch_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["amazon-cloudwatch"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["cloudwatch-agent"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgId"
      values   = ["$${aws:ResourceOrgId}"]
    }
  }
}

resource "aws_iam_role" "cloudwatch" {
  name               = "martin-project-final-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_trust.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
