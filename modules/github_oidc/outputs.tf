output "plan_role_github_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = aws_iam_role.github_plan.arn
}

output "apply_role_github_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = var.enable_apply_role_github ? aws_iam_role.github_apply[0].arn : null
}