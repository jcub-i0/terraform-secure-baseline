output "instance_profile_name" {
  description = "The 'name' attribute of the EC2 IAM Instance Profile"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "cloudtrail_role_arn" {
  value = aws_iam_role.cloudtrail.arn
}

output "flowlogs_role_arn" {
  value = aws_iam_role.flowlogs.arn
}

output "config_role_arn" {
  value = aws_iam_service_linked_role.config.arn
}

output "lambda_ec2_isolation_role_arn" {
  value = aws_iam_role.lambda_ec2_isolation.arn
}

output "lambda_ec2_rollback_role_arn" {
  value = aws_iam_role.lambda_ec2_rollback.arn
}

output "lambda_ip_enrichment_role_arn" {
  value = aws_iam_role.lambda_ip_enrichment.arn
}

output "config_remediation_role_arn" {
  value = aws_iam_role.config_remediation.arn
}

output "firehose_flow_logs_role_arn" {
  value = aws_iam_role.firehose_flow_logs.arn
}

output "cw_to_firehose_role_arn" {
  value = aws_iam_role.cw_to_firehose.arn
}

output "eventbridge_putevents_to_secops_role_arn" {
  value = aws_iam_role.eventbridge_putevents_to_secops.arn
}

output "patch_maintenance_window_role_arn" {
  value = aws_iam_role.patch_maintenance_window.arn
}

output "backup_service_role_arn" {
  value = aws_iam_role.backup.arn
}

output "logs_s3_readonly_policy_name" {
  value = aws_iam_policy.logs_s3_readonly.name
}

output "logs_cmk_decrypt_policy_name" {
  value = aws_iam_policy.logs_cmk_decrypt.name
}

output "break_glass_admin_role_arn" {
  value = aws_iam_role.break_glass_admin.arn
}

output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value       = var.enable_github_oidc ? module.github_oidc[0].github_plan_role_arn : null
}

output "github_plan_role_arn" {
  description = "ARN of the GitHub OIDC Terraform plan role"
  value = var.enable_apply_role_github ? module.github_oidc[0].github_apply_role_arn : null
}