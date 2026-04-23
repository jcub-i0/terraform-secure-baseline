output "dev_permission_set_arns" {
  description = "Permission set ARNs for the 'dev' environment"
  value = {
    operator_arn_dev = module.identity_center_dev.permission_set_arns
  }
}

output "prod_permission_set_arns" {
  description = "Permission set ARNs for the 'prod' environment"
  value = {
    operator_arn_prod = module.identity_center_prod.permission_set_arns
  }
}

output "staging_permission_set_arns" {
  description = "Permission set ARNs for the 'staging' environment"
  value = {
    operator_arn_staging = module.identity_center_staging.permission_set_arns
  }
}