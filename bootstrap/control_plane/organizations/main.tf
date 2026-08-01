/*
If AWS Organizations is not already enabled in the account, uncomment this resource
resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  aws_service_access_principals = []
  enabled_policy_types          = []
}
*/

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

resource "aws_organizations_aws_service_access" "securityhub" {
  count = var.enable_securityhub_delegated_administrator ? 1 : 0

  service_principal = "securityhub.amazonaws.com"
}

resource "aws_securityhub_organization_admin_account" "security_operations" {
  count = var.enable_securityhub_delegated_administrator ? 1 : 0

  admin_account_id = var.security_operations_account_id

  depends_on = [
    aws_organizations_aws_service_access.securityhub
  ]
}