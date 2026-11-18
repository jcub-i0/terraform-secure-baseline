locals {
  rds_identifier = "${var.name_prefix}-saas-db"
}

# CREATE DATA SECURITY GROUP, DB Subnet Group, AND RDS INSTANCE
## DATA SECURITY GROUP
resource "aws_security_group" "data" {
  name                   = "${var.name_prefix}-Data-SG"
  description            = "Security Group for the RDS database"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.name_prefix}-Data-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}

# Dedicated security group for temporary RDS Restore Testing instances.
# Validation ingress will be added separately with a narrowly scoped source.
resource "aws_security_group" "restore_test_db" {
  count = var.restore_testing_enabled ? 1 : 0

  name                   = "${var.name_prefix}-Restore-Test-DB-SG"
  description            = "Isolated temporary RDS Restore Testing database"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.name_prefix}-Restore-Test-DB-SG"
    Environment = var.environment
    Terraform   = "true"
    Purpose     = "rds-restore-testing"
  }
}

## DB SUBNET GROUP
resource "aws_db_subnet_group" "data" {
  name       = "${var.name_prefix}-data-db-subnet-group"
  subnet_ids = var.data_private_subnet_ids_list

  tags = {
    Name        = "${var.name_prefix}-Data-DB-Subnet-Group"
    Environment = var.environment
    Terraform   = "true"
  }
}

## RDS Instance
resource "aws_db_instance" "main" {
  identifier = local.rds_identifier

  engine         = "postgres"
  engine_version = "17.10"
  instance_class = var.rds_instance_class

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.data.id]

  multi_az            = var.rds_multi_az
  publicly_accessible = false

  db_name             = "appdb"
  username            = "${var.db_username}${var.environment}"
  password_wo         = ephemeral.aws_secretsmanager_random_password.rds_master.random_password
  password_wo_version = aws_secretsmanager_secret_version.rds_master.secret_string_wo_version

  deletion_protection      = var.rds_deletion_protection
  copy_tags_to_snapshot    = true
  skip_final_snapshot      = var.rds_skip_final_snapshot
  delete_automated_backups = var.rds_delete_automated_backups

  final_snapshot_identifier = (
    var.rds_skip_final_snapshot
    ? null
    : var.rds_final_snapshot_identifier
  )

  backup_retention_period = 14
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.rds_performance_insights_cmk_arn

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  auto_minor_version_upgrade = true

  depends_on = [
    aws_cloudwatch_log_group.rds_postgresql,
    aws_cloudwatch_log_group.rds_upgrade,
    aws_iam_role_policy_attachment.rds_enhanced_monitoring
  ]

  tags = {
    Name        = "${var.name_prefix}-SaaS-RDS"
    Environment = var.environment
    Terraform   = "true"
    Backup      = tostring(var.backup_enabled)
  }
}
