resource "aws_elasticache_subnet_group" "this" {
  name       = "martin-project-final"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "valkey" {
  name        = "martin-project-final-valkey"
  description = "Valkey access from the EKS cluster"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_cluster" {
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "martin-project-final"
  description          = "Expense cache for the Expensy backend"

  engine             = "valkey"
  engine_version     = "9.1"
  node_type          = "cache.t4g.micro"
  num_cache_clusters = 2
  port               = 6379
  cluster_mode       = "disabled"

  snapshot_retention_limit = 7

  automatic_failover_enabled = true
  multi_az_enabled           = true
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.valkey.id]

  user_group_ids = [aws_elasticache_user_group.this.id]

  apply_immediately = true
}

# ioredis sends INFO and CLIENT while connecting.
locals {
  valkey_users = {
    expensy = "on ~expenses -@all +get +set +del +info +client"
  }
}

# Write-only: the password never enters the state or a plan.
ephemeral "aws_secretsmanager_random_password" "valkey" {
  for_each = local.valkey_users

  password_length = 64
  # ElastiCache does not allow these in user passwords
  exclude_characters = ",\"/@"
}

resource "aws_secretsmanager_secret" "valkey" {
  for_each = local.valkey_users

  name        = "martin-project-final-valkey-${each.key}"
  description = "Valkey user and password for ${each.key}"
}

resource "aws_secretsmanager_secret_version" "valkey" {
  for_each = local.valkey_users

  secret_id = aws_secretsmanager_secret.valkey[each.key].id
  secret_string_wo = jsonencode({
    username = "martin-project-final-${each.key}"
    password = ephemeral.aws_secretsmanager_random_password.valkey[each.key].random_password
  })
  secret_string_wo_version = 1
}

ephemeral "aws_secretsmanager_secret_version" "valkey" {
  for_each = local.valkey_users

  secret_id = aws_secretsmanager_secret_version.valkey[each.key].secret_id
}

resource "aws_elasticache_user" "valkey" {
  for_each = local.valkey_users

  user_id       = "martin-project-final-${each.key}"
  user_name     = "martin-project-final-${each.key}"
  engine        = "valkey"
  access_string = each.value

  passwords_wo         = jsondecode(ephemeral.aws_secretsmanager_secret_version.valkey[each.key].secret_string).password
  passwords_wo_version = aws_secretsmanager_secret_version.valkey[each.key].secret_string_wo_version
}

# A Valkey-engine group has no usable default user.
resource "aws_elasticache_user_group" "this" {
  user_group_id = "martin-project-final"
  engine        = "valkey"
  user_ids      = [for user in aws_elasticache_user.valkey : user.user_id]
}
