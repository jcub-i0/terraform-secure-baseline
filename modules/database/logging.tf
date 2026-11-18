# CLOUDWATCH LOG GROUP FOR RDS POSTGRESQL LOGS
resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${local.rds_identifier}/postgresql"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-rds-postgresql-logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

# CLOUDWATCH LOG GROUP FOR RDS POSTGRESQL UDGRADE LOGS
resource "aws_cloudwatch_log_group" "rds_upgrade" {
  name              = "/aws/rds/instance/${local.rds_identifier}/upgrade"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-rds-upgrade-logs"
    Environment = var.environment
    Terraform   = "true"
  }
}
