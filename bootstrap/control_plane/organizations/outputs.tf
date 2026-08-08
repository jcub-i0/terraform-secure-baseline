output "organization_id" {
  description = "AWS Organizations organization ID"
  value       = aws_organizations_organization.main.id
}

output "organization_root_id" {
  description = "AWS Organizations root ID"
  value       = aws_organizations_organization.main.roots[0].id
}

output "organizational_unit_ids" {
  description = "AWS Organizations organizational unit IDs managed by this stack"

  value = {
    workloads = aws_organizations_organizational_unit.workloads.id
    nonprod   = aws_organizations_organizational_unit.nonprod.id
    prod      = aws_organizations_organizational_unit.prod.id
    security  = aws_organizations_organizational_unit.security.id
  }
}

output "security_operations_account_id" {
  description = "AWS account ID used for centralized security operations"
  value       = local.security_operations_account_id
}

output "central_security_features_enabled" {
  description = "Central security administration capabilities enabled by this stack"

  value = {
    securityhub_delegated_administrator    = var.enable_securityhub_delegated_administrator
    guardduty_delegated_administrator      = var.enable_guardduty_delegated_administrator
    securityhub_v2_organization_management = var.enable_securityhub_v2_organization_management
  }
}

output "delegated_administrator_account_ids" {
  description = "AWS account IDs configured as delegated administrators for centralized security services"

  value = {
    securityhub = try(
      aws_securityhub_organization_admin_account.security_operations[0].admin_account_id,
      null
    )

    guardduty = try(
      aws_guardduty_organization_admin_account.security_operations[0].admin_account_id,
      null
    )
  }
}