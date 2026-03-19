# BACKUP / DISASTER RECOVERY RESOURCES

# BACKUP VAULT
resource "aws_backup_vault" "main" {
  name = "${var.name_prefix}-backup-vault"
  kms_key_arn = var.backup_vault_cmk_arn

  tags = {
    Name = "${var.name_prefix}-daily-backup"
    Environment = var.environment
    Terraform = "true"
  }
}