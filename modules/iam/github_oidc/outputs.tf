output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = var.enable_github_oidc ? aws_iam_role.github_plan.arn : null
}