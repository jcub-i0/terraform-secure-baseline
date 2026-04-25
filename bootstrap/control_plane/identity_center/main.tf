locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

module "identity_center_dev" {
  source = "../../../modules/identity_center"

  account_id                   = var.account_id_dev
  environment                  = "dev"
  secops_operator_group_name   = "SecOps-Operator-Dev"
  secops_event_bus_arn         = "arn:aws:events:${var.primary_region_dev}:${var.account_id_dev}:event-bus/secops-bus"
  enable_secops_analyst        = var.enable_secops_analyst_dev
  enable_secops_engineer       = var.enable_secops_engineer_dev
  logs_cmk_decrypt_policy_name = var.logs_cmk_decrypt_policy_name_dev
  logs_s3_readonly_policy_name = var.logs_s3_readonly_policy_name_dev
  customer_managed_policy_path = "/"
}

module "identity_center_prod" {
  source = "../../../modules/identity_center"

  account_id                   = var.account_id_prod
  environment                  = "prod"
  secops_operator_group_name   = "SecOps-Operator-Prod"
  secops_event_bus_arn         = "arn:aws:events:${var.primary_region_prod}:${var.account_id_prod}:event-bus/secops-bus"
  enable_secops_analyst        = var.enable_secops_analyst_prod
  enable_secops_engineer       = var.enable_secops_engineer_prod
  logs_cmk_decrypt_policy_name = var.logs_cmk_decrypt_policy_name_prod
  logs_s3_readonly_policy_name = var.logs_s3_readonly_policy_name_prod
  customer_managed_policy_path = "/"
}

module "identity_center_staging" {
  source = "../../../modules/identity_center"

  account_id                   = var.account_id_staging
  environment                  = "staging"
  secops_operator_group_name   = "SecOps-Operator-Staging"
  secops_event_bus_arn         = "arn:aws:events:${var.primary_region_staging}:${var.account_id_staging}:event-bus/secops-bus"
  enable_secops_analyst        = var.enable_secops_analyst_staging
  enable_secops_engineer       = var.enable_secops_engineer_staging
  logs_cmk_decrypt_policy_name = var.logs_cmk_decrypt_policy_name_staging
  logs_s3_readonly_policy_name = var.logs_s3_readonly_policy_name_staging
  customer_managed_policy_path = "/"
}