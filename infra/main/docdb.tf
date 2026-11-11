# TLS is on through the docdb8.0 default parameter group (tls1.2+). The master
# user is only for the docdb-user Job; the backend connects as its own user.

resource "aws_docdb_subnet_group" "this" {
  name       = "martin-project-final"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "docdb" {
  name        = "martin-project-final-docdb"
  description = "DocumentDB access from the EKS cluster"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "docdb_from_cluster" {
  security_group_id            = aws_security_group.docdb.id
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier = "martin-project-final"
  engine             = "docdb"
  engine_version     = "8.0.3"

  master_username             = "expensyadmin"
  manage_master_user_password = true

  storage_encrypted      = true
  db_subnet_group_name   = aws_docdb_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.docdb.id]

  backup_retention_period = 7

  deletion_protection = false
  skip_final_snapshot = true

  apply_immediately = true
}

resource "aws_docdb_cluster_instance" "this" {
  identifier         = "martin-project-final-1"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = "db.t4g.medium"
  apply_immediately  = true
}

# Terraform has no DocumentDB user resource: the docdb-user Job creates the
# backend's user from this secret.
ephemeral "aws_secretsmanager_random_password" "docdb_app" {
  password_length    = 64
  exclude_characters = ",\"/@"
}

resource "aws_secretsmanager_secret" "docdb_app" {
  name        = "martin-project-final-docdb-expensy"
  description = "DocumentDB user and password for the Expensy backend"
}

resource "aws_secretsmanager_secret_version" "docdb_app" {
  secret_id = aws_secretsmanager_secret.docdb_app.id
  secret_string_wo = jsonencode({
    username = "expensy"
    password = ephemeral.aws_secretsmanager_random_password.docdb_app.random_password
  })
  secret_string_wo_version = 1
}
