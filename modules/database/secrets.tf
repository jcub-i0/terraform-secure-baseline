# RDS SECRET GENERATION/HANDLING, WHERE THE SECRET IS NEVER PERSISTED TO THE STATE
## Create a secret in AWS Secrets Manager
resource "aws_secretsmanager_secret" "rds_master" {
  name_prefix = "${var.name_prefix}/database/rds-master-"
  description = "Main RDS DB's master key"
  kms_key_id  = var.secrets_manager_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-RdsMasterSecret"
    Environment = var.environment
    Terraform   = "true"
  }
}

## Generate random secret
ephemeral "aws_secretsmanager_random_password" "rds_master" {
  password_length            = 20
  exclude_punctuation        = true
  require_each_included_type = true
}

## Store generated secret inside the secret in AWS Secrets Manager
resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string_wo = jsonencode({
    password = ephemeral.aws_secretsmanager_random_password.rds_master.random_password
  })
  secret_string_wo_version = 1
}

## Read back the rds_master secret ephemerally
ephemeral "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id

  depends_on = [
    aws_secretsmanager_secret_version.rds_master
  ]
}
