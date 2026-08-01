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