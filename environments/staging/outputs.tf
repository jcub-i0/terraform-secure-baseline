output "lambda_cmk_arn" {
  description = "ARN of the CMK used to encrypt Lambda functions"
  value       = module.baseline.lambda_cmk_arn
}

output "secrets_manager_cmk_arn" {
  description = "ARN of the CMK used to encrypt Secrets Manager secrets"
  value       = module.baseline.secrets_manager_cmk_arn
}