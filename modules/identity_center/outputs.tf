output "permission_set_arns" {
  description = "Permission set ARNs"
  value = {
    secops-analyst  = aws_ssoadmin_permission_set.secops_analyst.arn
    secops-engineer = aws_ssoadmin_permission_set.secops_engineer.arn
    secops-operator = aws_ssoadmin_permission_set.secops_operator.arn
  }
}