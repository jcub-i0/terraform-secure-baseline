output "instance_profile_name" {
  description = "The 'name' attribute of the EC2 IAM Instance Profile"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "cloudtrail_role_arn" {
  description = "CloudTrail CloudWatch Logs delivery role ARN, exposed only after its inline delivery policy is attached."
  value       = aws_iam_role.cloudtrail.arn

  depends_on = [
    aws_iam_role_policy.cloudtrail
  ]
}

output "flowlogs_role_arn" {
  description = "VPC Flow Logs CloudWatch Logs delivery role ARN, exposed only after its inline delivery policy is attached."
  value       = aws_iam_role.flowlogs.arn

  depends_on = [
    aws_iam_role_policy.flowlogs
  ]
}

output "config_role_arn" {
  description = "ARN of the AWS-managed Config service-linked role"
  value       = local.config_service_linked_role_arn
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
  description = "Firehose flow-log delivery role ARN, exposed only after its inline delivery policy is attached."
  value       = aws_iam_role.firehose_flow_logs.arn

  depends_on = [
    aws_iam_role_policy.firehose_flow_logs
  ]
}

output "cw_to_firehose_role_arn" {
  description = "CloudWatch Logs to Firehose role ARN, exposed only after its inline delivery policy is attached."
  value       = aws_iam_role.cw_to_firehose.arn

  depends_on = [
    aws_iam_role_policy.cw_to_firehose
  ]
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
