output "permission_set_arns" {
  description = "Permission set ARNs"
  value = merge(
    {
      secops-operator = aws_ssoadmin_permission_set.secops_operator.arn
    },

    var.enable_secops_analyst ? {
      secops-analyst = aws_ssoadmin_permission_set.secops_analyst.arn
    } : {},

    var.enable_secops_engineer ? {
      secops-engineer = aws_ssoadmin_permission_set.secops_engineer.arn
    } : {}
  )
}