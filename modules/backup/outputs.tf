output "backup_vault_name" {
    description = "The 'name' attribute of the Main AWS Backup Vault"
    value = aws_backup_vault.main.name
}

output "backup_plan_id" {
  description = "The 'id' attribute of the Main Backup Plan"
  value = aws_backup_plan.main.id
}