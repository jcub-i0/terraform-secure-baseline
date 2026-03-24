output "backup_vault_name" {
    description = "The 'Name' attribute of the Main AWS Backup Vault"
    value = aws_backup_vault.main.name
}