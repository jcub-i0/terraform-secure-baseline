output "managed_config_rule_names" {
  description = "Names of AWS-managed Config rules created by this baseline pack."
  value       = [for r in aws_config_config_rule.managed : r.name]
}

output "managed_config_rule_arns" {
  description = "ARNs of AWS-managed Config rules created by this baseline pack"
  value = [for r in aws_aws_config_config_rule.managed : r.arn]
}

output "s3_public_access_remediation_rule_name" {
  description = "Config rule name for S3 public access prohibition (auto-remediation target)."
  value       = aws_config_config_rule.s3_public_access_block.name
}

output "config_recorder_name" {
  description = "AWS Config configuration recorder name"
  value = aws_config_configuration_recorder.config.name
}

output "enabled_rule_families" {
  description = "Rule families enabled in this baseline"
  value = local.enabled_families
}