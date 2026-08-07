output "security_operations_account_id" {
  description = "AWS account ID managing centralized security services"
  value       = data.aws_caller_identity.current.account_id
}

output "securityhub_home_region" {
  description = "Security Hub home Region"
  value       = var.primary_region
}

output "securityhub_finding_aggregator_arn" {
  description = "ARN of the Security Hub finding aggregator"
  value       = aws_securityhub_finding_aggregator.main.arn
}

output "securityhub_central_configuration_enabled" {
  description = "Whether Security Hub central organization configuration is enabled"
  value       = var.enable_securityhub_organization_configuration
}

output "securityhub_cspm_configuration_policy_ids" {
  description = "Security Hub CSPM configuration policy IDs by AWS Organizations account name"

  value = {
    for account_name, policy in aws_securityhub_configuration_policy.account :
    account_name => policy.id
  }
}

output "securityhub_cspm_configuration_policy_arns" {
  description = "Security Hub CSPM configuration policy ARNs by AWS Organizations account name"

  value = {
    for account_name, policy in aws_securityhub_configuration_policy.account :
    account_name => policy.arn
  }
}

output "securityhub_cspm_policy_association_target_ids" {
  description = "AWS account IDs associated with Security Hub CSPM configuration policies"

  value = {
    for account_name, association in aws_securityhub_configuration_policy_association.account :
    account_name => association.target_id
  }
}

output "securityhub_cspm_account_ids" {
  description = "AWS Organizations account IDs discovered for Security Hub CSPM policy associations"
  value       = local.securityhub_cspm_association_account_ids
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for the security-operations delegated administrator account."
  value       = data.aws_guardduty_detector.main.id
}