locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

module "baseline" {
  source = "../.."

  cloud_name = var.cloud_name
  environment = var.environment
  bucket_admin_principals = var.bucket_admin_principals
  abuseipdb_api_key = var.abuseipdb_api_key
}