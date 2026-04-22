output "permission_set_arns" {
  description = "Permission set ARNs"
  value = {
    #analyst  = aws_ssoadmin_permission_set.secops_analyst.arn
    #engineer = aws_ssoadmin_permission_set.secops_engineer.arn
    operator_dev = module.identity_center_dev.secops_operator.arn
    operator_prod = module.identity_center_prod.secops_operator.arn
    operator_staging = module.identity_center_staging.secops_operator.arn
  }
}