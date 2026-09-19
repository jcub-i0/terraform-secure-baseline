output "backup_vault_name" {
  description = "The 'name' attribute of the Main AWS Backup Vault"
  value       = aws_backup_vault.main.name
}

output "backup_plan_id" {
  description = "The ID of the AWS Backup plan when backups are enabled; null otherwise."
  value       = var.backup_enabled ? aws_backup_plan.main[0].id : null
}