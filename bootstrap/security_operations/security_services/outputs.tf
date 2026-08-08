output "security_operations_account_id" {
  description = "AWS account ID managing centralized security services"
  value       = data.aws_caller_identity.current.account_id
}

output "securityhub_home_region" {
  description = "Security Hub home Region"
  value       = var.primary_region
}

output "central_security_features_enabled" {
  description = "Central security-service capabilities enabled by this stack"

  value = {
    securityhub_cspm = var.enable_securityhub_organization_configuration
    guardduty        = var.enable_guardduty_organization_configuration
    securityhub_v2   = var.enable_securityhub_v2_organization_policy
  }
}

output "securityhub_finding_aggregator_arn" {
  description = "ARN of the Security Hub finding aggregator"
  value       = aws_securityhub_finding_aggregator.main.arn
}

output "securityhub_cspm_configuration_policy_ids" {
  description = "Security Hub CSPM configuration policy IDs by AWS Organizations account name"

  value = {
    for account_name, policy in aws_securityhub_configuration_policy.account :
    account_name => policy.id
  }
}

output "securityhub_cspm_policy_association_target_ids" {
  description = "AWS account IDs associated with Security Hub CSPM configuration policies"

  value = {
    for account_name, association in aws_securityhub_configuration_policy_association.account :
    account_name => association.target_id
  }
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for the security-operations delegated administrator account"
  value       = data.aws_guardduty_detector.main.id
}

output "securityhub_v2_organization_policy_id" {
  description = "ID of the Security Hub V2 AWS Organizations policy"

  value = try(
    aws_organizations_policy.securityhub_v2_workloads[0].id,
    null
  )
}