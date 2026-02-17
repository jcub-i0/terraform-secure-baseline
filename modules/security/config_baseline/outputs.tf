output "managed_config_rule_names" {
  description = "Names of AWS-managed Config rules created by this baseline pack."
  value       = [for r in aws_config_config_rule.managed : r.name]
}

output "managed_config_rule_arns" {
  description = "ARNs of AWS-managed Config rules created by this baseline pack"
  value = [for r in aws_aws_config_config_rule.managed : r.arn]
}