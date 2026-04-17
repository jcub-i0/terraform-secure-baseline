#################################
# STATE STACK
#################################

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

module "state" {
  source = "../../../modules/state"

  name_prefix = local.name_prefix
  cloud_name              = var.cloud_name
  environment             = var.environment
  primary_region          = var.primary_region
  account_id              = var.account_id
  bucket_admin_principals = var.bucket_admin_principals
}