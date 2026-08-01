data "aws_organizations_organization" "main" {}

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"


  securityhub_standard_catalog = {
    aws_fsbp = "arn:aws:securityhub:${var.primary_region}::standards/aws-foundational-security-best-practices/v/1.0.0"

    aws_tagging = "arn:aws:securityhub:${var.primary_region}::standards/aws-resource-tagging-standard/v/1.0.0"

    cis_1_2 = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"

    cis_5_0 = "arn:aws:securityhub:${var.primary_region}::standards/cis-aws-foundations-benchmark/v/5.0.0"

    nist_800_53 = "arn:aws:securityhub:${var.primary_region}::standards/nist-800-53/v/5.0.0"

    pci_dss = "arn:aws:securityhub:${var.primary_region}::standards/pci-dss/v/4.0.1"
  }

  securityhub_enabled_standard_arns_dev = sort([
    for standard_key in var.securityhub_enabled_standard_keys_dev :
    local.securityhub_standard_catalog[standard_key]
  ])

  dev_accounts = [
    for account in data.aws_organizations_organization.main.accounts :
    account
    if account.name == var.dev_account_name &&
    account.state == "ACTIVE"
  ]

  dev_account_id = try(
    one(local.dev_accounts).id,
    null
  )
}

check "dev_account" {
  assert {
    condition = (
      !var.enable_securityhub_dev_configuration_policy_association ||
      length(local.dev_accounts) == 1
    )

    error_message = "Exactly one active AWS Organizations account named '${var.dev_account_name}' must exist when the dev Security Hub policy association is enabled."
  }
}

check "dev_policy_association_requires_policy" {
  assert {
    condition = (
      !var.enable_securityhub_dev_configuration_policy_association ||
      var.enable_securityhub_dev_configuration_policy
    )

    error_message = "The dev Security Hub configuration policy must be enabled before it can be associated."
  }
}

data "aws_caller_identity" "current" {}

check "target_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.account_id
    error_message = "The active AWS credentials do not belong to the configured security-operations account."
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

resource "aws_securityhub_configuration_policy" "dev" {
  count = var.enable_securityhub_dev_configuration_policy ? 1 : 0

  name        = "${local.name_prefix}-dev"
  description = "Central Security Hub CSPM configuration policy for the dev account"

  configuration_policy {
    service_enabled       = true
    enabled_standard_arns = local.securityhub_enabled_standard_arns_dev

    security_controls_configuration {
      disabled_control_identifiers = sort(
        tolist(var.securityhub_disabled_control_identifiers_dev)
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

resource "aws_securityhub_configuration_policy_association" "dev" {
  count = (
    var.enable_securityhub_dev_configuration_policy_association &&
    var.enable_securityhub_dev_configuration_policy
  ) ? 1 : 0

  target_id = local.dev_account_id
  policy_id = aws_securityhub_configuration_policy.dev[0].id

  depends_on = [
    aws_securityhub_organization_configuration.main,
    aws_securityhub_configuration_policy.dev,
  ]
}