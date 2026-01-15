output "cloudtrail_log_group_arn" {
  value = aws_cloudwatch_log_group.cloudtrail.arn
}

output "cloudtrail_arn" {
    description = "The ARN of the CloudTrail resource itself"
  value = aws_cloudtrail.cloudtrail.arn
}