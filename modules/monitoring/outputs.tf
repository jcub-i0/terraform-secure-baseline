output "compliance_topic_arn" {
  value = aws_sns_topic.compliance.arn
}

output "secops_topic_arn" {
  value = aws_sns_topic.secops.arn
}

output "sec_notifs_eventbridge_dlq_arn" {
  value = aws_sqs_queue.security_notifications_eventbridge_dlq.arn
}