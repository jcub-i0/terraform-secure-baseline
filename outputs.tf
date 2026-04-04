output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = module.github_oidc.github_plan_role_arn
}

output "github_apply_role_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value       = module.github_oidc.github_apply_role_arn
}