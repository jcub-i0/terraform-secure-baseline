output "instance_profile_name" {
  description = "The 'name' attribute of the EC2 IAM Instance Profile"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "config_role_arn" {
  description = "ARN of the AWS-managed Config service-linked role"
  value       = local.config_service_linked_role_arn
}

output "config_remediation_role_arn" {
  value = aws_iam_role.config_remediation.arn
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
