resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  enabled_policy_types = [
    "SECURITYHUB_POLICY",
  ]

  lifecycle {
    prevent_destroy = true

    ignore_changes = [
      aws_service_access_principals,
    ]
  }
}

data "aws_organizations_organization" "main" {}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.main.roots[0].id
}

resource "aws_organizations_organizational_unit" "nonprod" {
  name      = "NonProd"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = data.aws_organizations_organization.main.roots[0].id
}

##########################################
# SECURITY HUB ORGANIZATION INTEGRATION
##########################################

locals {
  security_operations_accounts = [
    for account in data.aws_organizations_organization.main.accounts :
    account
    if account.name == var.security_operations_account_name
  ]

  security_operations_account_id = try(
    one(local.security_operations_accounts).id,
    null
  )
}

check "security_operations_account" {
  assert {
    condition = (
      !var.enable_securityhub_delegated_administrator ||
      length(local.security_operations_accounts) == 1
    )
    error_message = "Exactly one AWS Organizations account name '${var.security_operations_account_name}' must exist."
  }
}

resource "aws_organizations_aws_service_access" "securityhub" {
  count = var.enable_securityhub_delegated_administrator ? 1 : 0

  service_principal = "securityhub.amazonaws.com"
}

resource "aws_securityhub_organization_admin_account" "security_operations" {
  count = var.enable_securityhub_delegated_administrator ? 1 : 0

  admin_account_id = local.security_operations_account_id

  depends_on = [
    aws_organizations_aws_service_access.securityhub
  ]
}

##########################################
# GUARDDUTY ORGANIZATION INTEGRATION
##########################################

resource "aws_organizations_aws_service_access" "guardduty" {
  count = var.enable_guardduty_delegated_administrator ? 1 : 0

  service_principal = "guardduty.amazonaws.com"
}

resource "aws_organizations_aws_service_access" "guardduty_malware_protection" {
  service_principal = "malware-protection.guardduty.amazonaws.com"
}

resource "aws_guardduty_organization_admin_account" "security_operations" {
  count = var.enable_guardduty_delegated_administrator ? 1 : 0

  admin_account_id = local.security_operations_account_id

  depends_on = [
    aws_organizations_aws_service_access.guardduty
  ]
}