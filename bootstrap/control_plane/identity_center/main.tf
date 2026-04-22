locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "account_id" {}

module "identity_center_dev" {
  source = "../../../modules/identity_center"

  account_id = var.dev_account_id
  environment = "dev"
  secops_operator_group_name = "SecOps-Operator-Dev"
  secops_event_bus_arn = "arn:aws:events:us-east-1:${var.dev_account_id}:event-bus/secops-bus"
}

/*
# FULL IDENTITY_CENTER MODULE CALL
module "identity_center" {
  source = "../modules/identity_center"

  account_id                   = data.aws_caller_identity.current.account_id
  secops_analyst_group_name    = "SecOps-Analysts"
  secops_engineer_group_name   = "SecOps-Engineers"
  secops_operator_group_name   = "SecOps-Operators"
  logs_cmk_decrypt_policy_name = module.iam.logs_cmk_decrypt_policy_name
  logs_s3_readonly_policy_name = module.iam.logs_s3_readonly_policy_name
  secops_event_bus_arn         = module.automation.secops_event_bus_arn
  environment                  = var.environment
  customer_managed_policy_path = "/"

  depends_on = [
    module.iam
  ]
}
*/