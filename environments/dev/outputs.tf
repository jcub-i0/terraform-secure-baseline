output "lambda_cmk_arn" {
  description = "ARN of the 'dev' env's CMK used to encrypt Lambda functions"
  value       = module.baseline.lambda_cmk_arn
}

output "secrets_manager_cmk_arn" {
  description = "ARN of the 'dev' env's CMK used to encrypt Secrets Manager secrets"
  value       = module.baseline.secrets_manager_cmk_arn
}

output "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the 'dev' env's 'Logs CMK Decrypt Policy' resource"
  value       = module.baseline.logs_cmk_decrypt_policy_name
}

output "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the 'dev' env's 'Logs S3 Readonly Policy' resource"
  value       = module.baseline.logs_s3_readonly_policy_name
}

output "deployment_profile" {
  description = "Selected deployment profile"
  value       = module.baseline.deployment_profile
}

output "egress_mode" {
  description = "Selected egress mode input"
  value       = module.baseline.egress_mode
}

output "effective_egress_mode" {
  description = "Effective egress mode after resolving deployment_profile and egress_mode"
  value       = module.baseline.effective_egress_mode
}