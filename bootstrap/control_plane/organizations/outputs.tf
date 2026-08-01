output "securityhub_delegated_administrator_account_id" {
  description = "Account ID designated as the Security Hub administrator"
  value = try(
    aws_securityhub_organization_admin_account.security_operations[0].admin_account_id,
    null
  )
}

output "securityhub_trusted_access_enabled" {
  description = "Whether trusted access for Security Hub is managed by this stack"
  value = var.enable_securityhub_delegated_administrator
}