locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "account_id" {}

module "identity_center_dev" {
  source = "../../../modules/identity_center"

  account_id                   = var.dev_account_id
  environment                  = "dev"
  secops_operator_group_name   = "SecOps-Operator-Dev"
  secops_event_bus_arn         = "arn:aws:events:${var.dev_primary_region}:${var.dev_account_id}:event-bus/secops-bus"
  enable_secops_analyst        = var.enable_secops_analyst
  enable_secops_engineer       = var.enable_secops_engineer
  logs_cmk_decrypt_policy_name = var.dev_logs_cmk_decrypt_policy_name
  logs_s3_readonly_policy_name = var.dev_logs_s3_readonly_policy_name
  customer_managed_policy_path = "/"
}

module "identity_center_prod" {
  source = "../../../modules/identity_center"

  account_id                 = var.prod_account_id
  environment                = "prod"
  secops_operator_group_name = "SecOps-Operator-Prod"
  secops_event_bus_arn       = "arn:aws:events:${var.prod_primary_region}:${var.prod_account_id}:event-bus/secops-bus"
  enable_secops_analyst        = var.enable_secops_analyst
  enable_secops_engineer       = var.enable_secops_engineer
  logs_cmk_decrypt_policy_name = var.prod_logs_cmk_decrypt_policy_name
  logs_s3_readonly_policy_name = var.prod_logs_s3_readonly_policy_name
  customer_managed_policy_path = "/"
}

module "identity_center_staging" {
  source = "../../../modules/identity_center"

  account_id                 = var.staging_account_id
  environment                = "staging"
  secops_operator_group_name = "SecOps-Operator-Staging"
  secops_event_bus_arn       = "arn:aws:events:${var.staging_primary_region}:${var.staging_account_id}:event-bus/secops-bus"
}