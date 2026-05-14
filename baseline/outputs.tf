output "lambda_cmk_arn" {
  description = "ARN of the CMK used to encrypt Lambda functions"
  value       = module.security.lambda_cmk_arn
}

output "secrets_manager_cmk_arn" {
  description = "ARN of the CMK used to encrypt Secrets Manager secrets"
  value       = module.security.secrets_manager_cmk_arn
}

output "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the 'Logs CMK Decrypt Policy' resource"
  value       = module.iam.logs_cmk_decrypt_policy_name
}

output "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the 'Logs S3 Readonly Policy' resource"
  value       = module.iam.logs_s3_readonly_policy_name
}

output "deployment_profile" {
  description = "Selected deployment profile"
  value = var.deployment_profile
}

output "egress_mode" {
  description = "Selected egress mode input"
  value = var.egress_mode
}

output "effective_egress_mode" {
  description = "Effective egress mode after resolving deployment_profile and egress_mode"
  value = local.effective_egress_mode
}