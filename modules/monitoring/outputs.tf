output "compliance_topic_arn" {
  value = aws_sns_topic.compliance.arn
}

output "secops_topic_arn" {
  value = aws_sns_topic.secops.arn
}