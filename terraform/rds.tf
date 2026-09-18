# PostgreSQL, reachable only from inside the cluster.

# ------------------------------------------------------------ security group --

# EKS creates a security group for the cluster and attaches it to every node, so
# allowing traffic from that group means "allow the pods" without hardcoding any
# IP addresses. Nodes replaced by an autoscaler keep working automatically.
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "PostgreSQL access from EKS worker nodes only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds-sg" }

  lifecycle {
    # An SG cannot be deleted while an RDS network interface still references it,
    # so create the replacement before destroying the old one.
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id = aws_security_group.rds.id
  description       = "PostgreSQL from EKS nodes"

  # Source is a security group, not a CIDR. This is the important part: there is
  # no IP range here that could accidentally include the internet.
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

  from_port   = 5432
  to_port     = 5432
  ip_protocol = "tcp"
}

# ------------------------------------------------------------ subnet group --

# RDS requires a subnet group spanning at least two AZs, even for a single-AZ
# instance. The default VPC has no default subnet group, which is why creating
# RDS from the CLI fails with a confusing error while the console appears to work
# -- the console silently creates one for you.
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.name}-db-subnet-group" }
}

# ---------------------------------------------------------------- password --

resource "random_password" "db" {
  length = 24

  # Alphanumeric only, deliberately. RDS rejects some punctuation outright, and
  # characters like @ : / ? # would need percent-encoding inside DATABASE_URL --
  # producing an authentication failure that looks nothing like a quoting bug.
  special = false
}

# ---------------------------------------------------------------- instance --

resource "aws_db_instance" "main" {
  identifier = "${local.name}-db"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # The database has no public IP at all. Combined with private subnets that have
  # no internet route, this is two independent reasons it is unreachable from
  # outside the VPC.
  publicly_accessible = false
  multi_az            = var.db_multi_az

  # Automated minor version upgrades during the maintenance window.
  auto_minor_version_upgrade = true

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = var.db_deletion_protection

  # Terraform would otherwise show a diff on every plan as AWS applies minor
  # version upgrades on its own schedule.
  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = { Name = "${local.name}-db" }
}

# ------------------------------------------------------------------ secret --

# The connection string lives in Secrets Manager rather than in a Terraform
# output or a committed file. The CD workflow reads it at deploy time and turns
# it into a Kubernetes Secret, so the password never passes through GitHub.
resource "aws_secretsmanager_secret" "db" {
  name        = "${local.name}/database-url"
  description = "PostgreSQL connection string for the Todo API"

  # Default is a 30-day recovery window, during which the NAME stays reserved.
  # That makes destroy-then-apply fail with "already scheduled for deletion",
  # which is a genuinely confusing wall to hit while iterating.
  recovery_window_in_days = 0

  tags = { Name = "${local.name}-database-url" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    DATABASE_URL = "postgresql://${var.db_username}:${random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
    host         = aws_db_instance.main.address
    port         = aws_db_instance.main.port
    dbname       = var.db_name
    username     = var.db_username
    password     = random_password.db.result
  })
}

# Lets the CI principal read that secret during deployment.
data "aws_iam_policy_document" "read_db_secret" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_policy" "read_db_secret" {
  name        = "${local.name}-read-db-secret"
  description = "Read the Todo API database connection string"
  policy      = data.aws_iam_policy_document.read_db_secret.json

  tags = { Name = "${local.name}-read-db-secret" }
}
