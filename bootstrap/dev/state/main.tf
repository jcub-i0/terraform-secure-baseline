#################################
# STATE STACK
#################################

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "account_id" {}

module "state" {
  source = "../../../modules/state"

  name_prefix             = local.name_prefix
  cloud_name              = var.cloud_name
  environment             = var.environment
  primary_region          = var.primary_region
  account_id              = data.aws_caller_identity.account_id.account_id
  bucket_admin_principals = var.bucket_admin_principals
}