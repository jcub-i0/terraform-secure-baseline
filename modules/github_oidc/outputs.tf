output "plan_role_github_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value       = aws_iam_role.github_plan.arn
}

output "apply_role_github_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value = (
    var.enable_apply_role_github
    ? aws_iam_role.github_apply[0].arn
    : null
  )
}

output "image_publisher_role_github_arn" {
  description = "ARN of the GitHub OIDC image publisher role"
  value = (
    var.enable_image_publisher_role_github
    ? aws_iam_role.github_image_publisher[0].arn
    : null
  )
}