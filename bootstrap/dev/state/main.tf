#################################
# STATE STACK
#################################

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

module "state" {
  source = "../../../modules/state"

  name_prefix             = local.name_prefix
  cloud_name              = var.cloud_name
  environment             = var.environment
  account_id              = data.aws_caller_identity.current.account_id
  bucket_admin_principals = var.bucket_admin_principals
}