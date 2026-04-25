output "permission_set_arns" {
  description = "Permission set ARNs"
  value = {
    analyst  = aws_ssoadmin_permission_set.secops_analyst.arn
    engineer = aws_ssoadmin_permission_set.secops_engineer.arn
    operator = aws_ssoadmin_permission_set.secops_operator.arn
  }
}