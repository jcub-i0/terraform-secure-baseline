output "compliance_topic_arn" {
  value = aws_sns_topic.compliance.arn
}

output "security_topic_arn" {
  value = aws_sns_topic.security.arn
}