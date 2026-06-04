output "vpc_id" {
  description = "ID of the main VPC"
  value       = module.networking.vpc_id
}

output "name_prefix" {
  description = "Prefix/suffix used in naming convention ({CLOUD_NAME}-{ENV})"
  value       = local.name_prefix
}

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
  value       = var.deployment_profile
}

output "egress_mode" {
  description = "Selected egress mode input."
  value       = var.egress_mode
}

output "effective_egress_mode" {
  description = "Effective egress mode after resolving deployment_profile and egress_mode"
  value       = local.effective_egress_mode
}

output "effective_cloudwatch_retention_days" {
  description = "Effective CloudWatch Logs retention period after resolving deployment_profile and cloudwatch_retention_days override"
  value       = local.effective_cloudwatch_retention_days
}

output "effective_enable_config" {
  description = "Effective AWS Config enablement after resolving deployment_profile and enable_config override."
  value       = local.effective_enable_config
}

output "effective_enable_rules" {
  description = "Effective AWS Config rule group settings after resolving deployment_profile, enable_config, and enable_rules."
  value       = local.effective_enable_rules
}

output "effective_backup_enabled" {
  description = "Effective AWS Backup enablement after resolving deployment_profile."
  value       = local.effective_backup_enabled
}

output "effective_inspector_enabled" {
  description = "Effective Inspector enablement after resolving deployment_profile."
  value       = local.effective_inspector_enabled
}