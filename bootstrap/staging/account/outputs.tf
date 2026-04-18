output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = try(module.github_oidc[0].github_plan_role_arn, null)
}

output "apply_role_github_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value       = try(module.github_oidc[0].apply_role_github_arn, null)
}