locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
resource "random_id" "random_id" { byte_length = 4 }

module "baseline" {
  source = "../../baseline"

  cloud_name                         = var.cloud_name
  environment                        = var.environment
  account_id = data.aws_caller_identity.current.account_id
  primary_region                     = var.primary_region
  bucket_admin_principals            = var.bucket_admin_principals
  abuseipdb_api_key                  = var.abuseipdb_api_key
  config_enabled                     = var.config_enabled
  backup_enabled                     = var.backup_enabled
  break_glass_trusted_principal_arns = var.break_glass_trusted_principal_arns
  secops_emails                      = var.secops_emails
}