output "tamper_detection_rule_name" {
  value = aws_cloudwatch_event_rule.tamper_detection.name
}

output "tamper_detection_rule_arn" {
  value = aws_cloudwatch_event_rule.tamper_detection.arn
}