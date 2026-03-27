output "logs_cmk_arn" {
  description = "The ARN of the KMS CMK"
  value       = aws_kms_key.logs.arn
}

output "ebs_cmk_arn" {
  description = "The ARN of the EBS KMS CMK"
  value       = aws_kms_key.ebs.arn
}

output "ebs_cmk_alias_arn" {
  description = "The EBS KMS CMK alias"
  value       = aws_kms_alias.ebs.arn
}

output "lambda_cmk_arn" {
  description = "ARN of the Lambda CMK KMS key used to encrypt environment variables"
  value       = aws_kms_key.lambda.arn
}

output "secrets_manager_cmk_arn" {
  description = "ARN of the SecretsManager CMK"
  value       = aws_kms_key.secrets_manager.arn
}

output "secrets_manager_cmk_alias_arn" {
  description = "ARN of the SecretsManager CMK's alias"
  value       = aws_kms_alias.secrets_manager.arn
}

output "backup_vault_cmk_arn" {
  description = "ARN of the Backup Vault CMK"
  value       = aws_kms_key.backup_vault.arn
}

output "backup_vault_cmk_alias_arn" {
  description = "ARN of the Backup Vault CMK's alias"
  value       = aws_kms_alias.backup_vault.arn
}

output "sec_hub_inspector_high_critical_rule_arn" {
  description = "ARN of the SecurityHub/Inspector High/Critical eventbridge rule target"
  value       = aws_cloudwatch_event_rule.sec_hub_inspector_high_critical.arn
}

##################################
# TAMPER DETECTION MODULE OUTPUTS
##################################

output "tamper_detection_rule_name" {
  value = module.tamper_detection.tamper_detection_rule_name
}

output "tamper_detection_rule_arn" {
  value = module.tamper_detection.tamper_detection_rule_arn
}