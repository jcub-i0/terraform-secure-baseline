output "lambda_cmk_arn_dev" {
  description = "ARN of the 'dev' env's CMK used to encrypt Lambda functions"
  value       = module.baseline.lambda_cmk_arn
}

output "secrets_manager_cmk_arn_dev" {
  description = "ARN of the 'dev' env's CMK used to encrypt Secrets Manager secrets"
  value       = module.baseline.secrets_manager_cmk_arn
}

output "logs_cmk_decrypt_policy_name_dev" {
  description = "'Name' attribute of the 'dev' env's 'Logs CMK Decrypt Policy' resource"
  value       = module.baseline.logs_cmk_decrypt_policy_name
}

output "logs_s3_readonly_policy_name_dev" {
  description = "'Name' attribute of the 'dev' env's 'Logs S3 Readonly Policy' resource"
  value       = module.baseline.logs_s3_readonly_policy_name
}