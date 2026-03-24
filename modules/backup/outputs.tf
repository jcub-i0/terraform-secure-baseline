output "permission_set_arns" {
  description = "Permission set ARNs"
  value = {
    analyst  = aws_ssoadmin_permission_set.analyst.arn
    engineer = aws_ssoadmin_permission_set.engineer.arn
  }
}