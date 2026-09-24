output "backup_vault_name" {
  description = "The 'name' attribute of the Main AWS Backup Vault"
  value       = aws_backup_vault.main.name
}

output "backup_plan_id" {
  description = "The ID of the AWS Backup plan when backups are enabled; null otherwise."
  value       = var.backup_enabled ? aws_backup_plan.main[0].id : null
}

output "restore_testing_plan" {
  description = "Terraform-managed RDS Restore Testing plan metadata; null when Restore Testing is disabled."

  value = var.restore_testing_enabled ? {
    name = aws_backup_restore_testing_plan.rds[0].name
    arn  = aws_backup_restore_testing_plan.rds[0].arn

    schedule_expression = (
      aws_backup_restore_testing_plan.rds[0].schedule_expression
    )

    start_window_hours = (
      aws_backup_restore_testing_plan.rds[0].start_window_hours
    )

    recovery_point_selection = (
      aws_backup_restore_testing_plan.rds[0].recovery_point_selection
    )
  } : null
}

output "restore_testing_selection" {
  description = "Terraform-managed RDS Restore Testing selection metadata; null when Restore Testing is disabled."

  value = var.restore_testing_enabled ? {
    name = aws_backup_restore_testing_selection.rds[0].name

    restore_testing_plan_name = (
      aws_backup_restore_testing_selection.rds[0].restore_testing_plan_name
    )

    protected_resource_type = (
      aws_backup_restore_testing_selection.rds[0].protected_resource_type
    )

    protected_resource_arns = (
      aws_backup_restore_testing_selection.rds[0].protected_resource_arns
    )

    iam_role_arn = (
      aws_backup_restore_testing_selection.rds[0].iam_role_arn
    )

    restore_metadata_overrides = (
      aws_backup_restore_testing_selection.rds[0].restore_metadata_overrides
    )

    validation_window_hours = (
      aws_backup_restore_testing_selection.rds[0].validation_window_hours
    )
  } : null
}