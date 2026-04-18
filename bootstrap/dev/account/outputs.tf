output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = try(module.github_oidc[0].github_plan_role_arn, null)
}

output "github_apply_role_arn" {
  description = "ARN of the GitHub OIDC Terraform apply role"
  value       = try(module.github_oidc[0].github_apply_role_arn, null)
}