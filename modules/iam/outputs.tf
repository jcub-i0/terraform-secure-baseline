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

output "secops_role_arn" {
  value = aws_iam_role.secops.arn
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