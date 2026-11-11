# Sensitive wherever the value holds the account ID or the zone ID, so no log shows it.

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_arn" {
  value     = module.eks.cluster_arn
  sensitive = true
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "service_cidr" {
  value = local.service_cidr
}

output "argocd_server_url" {
  value = module.argocd.argocd_server_url
}

output "argocd_version" {
  value = module.argocd.version
}

output "node_iam_role_name" {
  value = module.eks.node_iam_role_name
}

output "docdb_endpoint" {
  value = aws_docdb_cluster.this.endpoint
}

output "docdb_port" {
  value = aws_docdb_cluster.this.port
}

output "docdb_master_secret_arn" {
  value     = local.docdb_master_secret_arn
  sensitive = true
}

output "docdb_app_secret_arn" {
  value     = aws_secretsmanager_secret.docdb_app.arn
  sensitive = true
}

output "valkey_primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "valkey_port" {
  value = aws_elasticache_replication_group.this.port
}

output "valkey_secret_arn" {
  value     = aws_secretsmanager_secret.valkey["expensy"].arn
  sensitive = true
}

output "valkey_username" {
  value = aws_elasticache_user.valkey["expensy"].user_name
}

output "ecr_registry" {
  value     = split("/", aws_ecr_repository.this["backend"].repository_url)[0]
  sensitive = true
}

output "github_build_role_arn" {
  value     = aws_iam_role.github["build"].arn
  sensitive = true
}

output "github_record_role_arn" {
  value     = aws_iam_role.github["record"].arn
  sensitive = true
}

output "zone_id" {
  value     = local.hosted_zone_id
  sensitive = true
}
