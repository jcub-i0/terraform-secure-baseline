# BACKUP / DISASTER RECOVERY RESOURCES

# BACKUP VAULT
resource "aws_backup_vault" "main" {
  name        = "${var.name_prefix}-backup-vault"
  kms_key_arn = var.backup_vault_cmk_arn

  force_destroy = var.force_destroy

  tags = {
    Name        = "${var.name_prefix}-daily-backup"
    Environment = var.environment
    Terraform   = "true"
  }
}

# BACKUP PLAN
resource "aws_backup_plan" "main" {
  count = var.backup_enabled ? 1 : 0

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
  count = var.backup_enabled ? 1 : 0

  name         = "${var.name_prefix}-backup-selection"
  plan_id      = aws_backup_plan.main[0].id
  iam_role_arn = var.backup_service_role_arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_tag_key
    value = "true"
  }
}

locals {
  restore_testing_name_prefix = replace(var.name_prefix, "-", "_")
}

resource "aws_backup_restore_testing_plan" "rds" {
  count = var.restore_testing_enabled ? 1 : 0

  name = "${local.restore_testing_name_prefix}_rds_restore_test"

  schedule_expression = var.restore_testing_schedule
  start_window_hours  = var.restore_testing_start_window_hours

  recovery_point_selection {
    algorithm = "LATEST_WITHIN_WINDOW"

    include_vaults = [
      aws_backup_vault.main.arn
    ]

    recovery_point_types = [
      "SNAPSHOT"
    ]

    selection_window_days = (
      var.restore_testing_selection_window_days
    )
  }

  tags = {
    Name        = "${var.name_prefix}-rds-restore-test"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_backup_restore_testing_selection" "rds" {
  count = var.restore_testing_enabled ? 1 : 0

  name = "rds_restore"

  restore_testing_plan_name = (
    aws_backup_restore_testing_plan.rds[0].name
  )

  protected_resource_type = "RDS"

  protected_resource_arns = [
    var.restore_testing_rds_arn
  ]

  iam_role_arn = var.backup_service_role_arn

  restore_metadata_overrides = {
    dbSubnetGroupName = (
      var.restore_testing_db_subnet_group_name
    )

    vpcSecurityGroupIds = jsonencode(
      var.restore_testing_vpc_security_group_ids
    )

    publiclyAccessible = "false"
    multiAz            = "false"
  }

  validation_window_hours = (
    var.restore_testing_validation_window_hours
  )
}