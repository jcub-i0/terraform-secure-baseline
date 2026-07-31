output "permission_set_arns" {
  description = "Permission set ARNs"

  value = merge(
    var.enable_secops_operator ? {
      "secops-operator" = aws_ssoadmin_permission_set.secops_operator[0].arn
    } : {},

    var.enable_secops_analyst ? {
      "secops-analyst" = aws_ssoadmin_permission_set.secops_analyst[0].arn
    } : {},

    var.enable_secops_engineer ? {
      "secops-engineer" = aws_ssoadmin_permission_set.secops_engineer[0].arn
    } : {}
  )
}