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

output "ecs_task_execution_roles" {
  description = "ECS task execution roles keyed by service name"

  value = {
    for service_name, role in aws_iam_role.ecs_task_execution_roles : service_name => {
      arn  = role.arn
      name = role.name
    }
  }
}

output "ecs_task_execution_policy_ids" {
  description = "ECS task execution inline-policy IDs keyed by service name"

  value = {
    for service_name, policy in aws_iam_role_policy.ecs_task_execution_policies :
    service_name => policy.id
  }
}

output "ecs_task_roles" {
  description = "ECS application task roles keyed by service name"

  value = {
    for service_name, role in aws_iam_role.ecs_task_roles : service_name => {
      arn  = role.arn
      name = role.name
    }
  }
}