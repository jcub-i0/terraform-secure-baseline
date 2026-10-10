output "permission_set_arns" {
  description = "Baseline-managed permission set ARNs"

  value = merge(
    var.enable_secops_administrator ? {
      "secops-administrator" = aws_ssoadmin_permission_set.secops_administrator[0].arn
    } : {},

    var.enable_secops_operator ? {
      "secops-operator" = aws_ssoadmin_permission_set.secops_operator[0].arn
    } : {}
  )
}
