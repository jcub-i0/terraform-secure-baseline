output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = aws_iam_role.github_plan.arn
}

output "github_apply_role_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value       = aws_iam_role.github_apply.arn
}