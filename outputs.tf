output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = module.iam.github_plan_role_arn
}

output "github_apply_role_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value       = module.iam.github_apply_role_arn
}