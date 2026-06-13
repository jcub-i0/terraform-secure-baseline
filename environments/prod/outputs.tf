output "vpc_id" {
  description = "ID of the main VPC"
  value       = module.baseline.vpc_id
}

output "name_prefix" {
  description = "Prefix/suffix used in naming convention ({CLOUD_NAME}-{ENV})"
  value       = module.baseline.name_prefix
}

output "centralized_logs_bucket_name" {
  description = "Name of the Centralized Logs S3 bucket ('bucket' S3 attribute)"
  value       = module.baseline.centralized_logs_bucket_name
}

output "lambda_cmk_arn" {
  description = "ARN of the 'prod' env's CMK used to encrypt Lambda functions"
  value       = module.baseline.lambda_cmk_arn
}

output "secrets_manager_cmk_arn" {
  description = "ARN of the 'prod' env's CMK used to encrypt Secrets Manager secrets"
  value       = module.baseline.secrets_manager_cmk_arn
}

output "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the 'prod' env's 'Logs CMK Decrypt Policy' resource"
  value       = module.baseline.logs_cmk_decrypt_policy_name
}

output "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the 'prod' env's 'Logs S3 Readonly Policy' resource"
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

output "effective_cloudwatch_retention_days" {
  description = "Effective CloudWatch Logs retention period after resolving deployment_profile and cloudwatch_retention_days override"
  value       = module.baseline.effective_cloudwatch_retention_days
}

output "effective_enable_config" {
  description = "Effective AWS Config enablement after resolving deployment_profile and enable_config override"
  value       = module.baseline.effective_enable_config
}

output "effective_enable_rules" {
  description = "Effective AWS Config rule group settings after resolving deployment_profile, enable_config, and enable_rules"
  value       = module.baseline.effective_enable_rules
}

output "effective_backup_enabled" {
  description = "Effective AWS Backup enablement after resolving deployment_profile"
  value       = module.baseline.effective_backup_enabled
}

output "effective_inspector_enabled" {
  description = "Effective Inspector enablement after resolving deployment_profile"
  value       = module.baseline.effective_inspector_enabled
}

output "db_port" {
  description = "Port used by the database (Postgres=5432, MySQL=3306)"
  value = module.baseline.db_port
}