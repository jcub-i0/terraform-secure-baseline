# BACKUP / DISASTER RECOVERY RESOURCES

# BACKUP VAULT
resource "aws_backup_vault" "main" {
  name        = "${var.name_prefix}-backup-vault"
  kms_key_arn = var.backup_vault_cmk_arn

  force_destroy = true # CHANGE THIS IN PROD

  tags = {
    Name        = "${var.name_prefix}-daily-backup"
    Environment = var.environment
    Terraform   = "true"
  }
}

# BACKUP PLAN
resource "aws_backup_plan" "main" {
  name = "${var.name_prefix}-backup-plan"

  rule {
    rule_name         = "daily-backups"
    target_vault_name = aws_backup_vault.main.name
    schedule          = var.backup_schedule

    lifecycle {
      delete_after = var.delete_backups_after_days
    }

    recovery_point_tags = {
      Name        = "${var.name_prefix}-daily-backup"
      Environment = var.environment
      Terraform   = "true"
    }
  }

  tags = {
    Name        = "${var.name_prefix}-backup-plan"
    Environment = var.environment
    Terraform   = "true"
  }
}

# BACKUP SELECTION
resource "aws_backup_selection" "main" {
  name         = "${var.name_prefix}-backup-selection"
  plan_id      = aws_backup_plan.main.id
  iam_role_arn = var.backup_service_role_arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_tag_key
    value = var.backup_tag_value
  }
}