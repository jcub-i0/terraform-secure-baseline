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