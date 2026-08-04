data "aws_organizations_organization" "main" {}

data "aws_caller_identity" "current" {}

check "target_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.account_id
    error_message = "The active AWS credentials do not belong to the configured security-operations account."
  }
}

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
  securityhub_standard_catalog = {
    aws_fsbp    = "arn:aws:securityhub:${var.primary_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
    aws_tagging = "arn:aws:securityhub:${var.primary_region}::standards/aws-resource-tagging-standard/v/1.0.0"
    cis_1_2     = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"
    cis_5_0     = "arn:aws:securityhub:${var.primary_region}::standards/cis-aws-foundations-benchmark/v/5.0.0"
    nist_800_53 = "arn:aws:securityhub:${var.primary_region}::standards/nist-800-53/v/5.0.0"
    pci_dss     = "arn:aws:securityhub:${var.primary_region}::standards/pci-dss/v/4.0.1"
  }

  securityhub_cspm_policies = {
    for account_name, configuration in var.securityhub_cspm_account_policies :
    account_name => configuration
    if configuration.create_policy
  }

  securityhub_cspm_associations = {
    for account_name, configuration in var.securityhub_cspm_account_policies :
    account_name => configuration
    if configuration.create_policy && configuration.associate_policy
  }

  securityhub_cspm_enabled_standard_arns = {
    for account_name, configuration in var.securityhub_cspm_account_policies :
    account_name => sort([
      for standard in configuration.enabled_standards :
      local.securityhub_standard_catalog[standard]
    ])
  }

  securityhub_cspm_association_accounts = {
    for account_name, configuration in local.securityhub_cspm_associations :
    account_name => [
      for account in data.data.aws_organizations_organization.main[accounts] :
      account
      if account.name == account_name &&
      account.state == "ACTIVE"
    ]
  }

  securityhub_cspm_association_account_ids = {
    for account_name, accounts in local.securityhub_cspm_association_accounts :
    account_name => try(
      one(accounts).id,
      null
    )
  }
}

check "securityhub_cspm_association_accounts" {
  assert {
    condition = alltrue([
      for account_name, accounts in local.securityhub_cspm_association_accounts :
      length(accounts) == 1
    ])

    error_message = "Each associated Security Hub CSPM policy must match exactly one active AWS Organizations accoutn using the policy map key as the account name."
  }
}

##########################################
# SECURITY HUB ADMINISTRATOR ACCOUNT
##########################################

resource "aws_securityhub_account" "main" {
  enable_default_standards = false
  auto_enable_controls     = false
}

##########################################
# SECURITY HUB HOME REGION
##########################################

resource "aws_securityhub_finding_aggregator" "main" {
  linking_mode = "NO_REGIONS"

  depends_on = [
    aws_securityhub_account.main
  ]
}

##########################################
# CENTRAL ORGANIZATION CONFIGURATION
##########################################

resource "aws_securityhub_organization_configuration" "main" {
  count = var.enable_securityhub_organization_configuration ? 1 : 0

  auto_enable           = false
  auto_enable_standards = "NONE"

  organization_configuration {
    configuration_type = "CENTRAL"
  }

  depends_on = [
    aws_securityhub_finding_aggregator.main
  ]
}

##########################################
# SECURITY HUB DEV CONFIGURATION POLICY
##########################################

resource "aws_securityhub_configuration_policy" "account" {
  for_each = local.securityhub_cspm_policies

  name        = "${local.name_prefix}-${each.key}"
  description = "Central Security Hub CSPM configuration policy for the ${each.key} account"

  configuration_policy {
    service_enabled       = true
    enabled_standard_arns = local.securityhub_cspm_enabled_standard_arns[each.key]

    security_controls_configuration {
      disabled_control_identifiers = sort(
        tolist(each.value.disabled_control_identifiers)
      )
    }
  }

  lifecycle {
    precondition {
      condition     = var.enable_securityhub_organization_configuration
      error_message = "Security Hub central organization configuration must be enabled before creating configuration policies."
    }
  }

  depends_on = [
    aws_securityhub_organization_configuration.main
  ]
}

##########################################
# DEV CONFIGURATION POLICY ASSOCIATION
##########################################

resource "aws_securityhub_configuration_policy_association" "account" {
  for_each = local.securityhub_cspm_associations

  target_id = local.securityhub_cspm_association_account_ids[each.key]
  policy_id = aws_securityhub_configuration_policy.account[each.key].id

  lifecycle {
    precondition {
      condition = (
        length(local.securityhub_cspm_association_accounts[each.key]) == 1
      )

      error_message = "Exactly one active AWS Organizations account named '${each.key}' must exist before its Security Hub CSPM policy can be associated."
    }
  }
}