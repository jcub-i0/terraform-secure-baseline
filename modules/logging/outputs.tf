output "cloudtrail_log_group_arn" {
  value = aws_cloudwatch_log_group.cloudtrail.arn
}

output "cloudtrail_logs_group_name" {
  value = aws_cloudwatch_log_group.cloudtrail.name
}