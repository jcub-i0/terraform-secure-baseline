output "instance_profile_name" {
  description = "The 'name' attribute of the EC2 IAM Instance Profile"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "cloudtrail_role_arn" {
  value = aws_iam_role.cloudtrail.arn
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