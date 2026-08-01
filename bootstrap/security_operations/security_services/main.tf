locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
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