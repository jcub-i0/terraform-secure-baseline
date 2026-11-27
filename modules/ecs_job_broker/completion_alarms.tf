resource "aws_cloudwatch_metric_alarm" "broker_completion_dlq_visible" {
  for_each = aws_sqs_queue.broker_completion_dlq

  alarm_name        = "${var.name_prefix}-job-completion-${each.key}-dlq-messages"
  alarm_description = "Completion events require protected investigation; DLQ presence does not authorize slot release."

  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = each.value.name }
  alarm_actions       = [var.alarm_topic_arn]

  tags = {
    Name        = "${var.name_prefix}-job-completion-${each.key}-dlq-messages"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_cloudwatch_metric_alarm" "broker_completion_dlq_delivery_failed" {
  count = local.completion_enabled ? 1 : 0

  alarm_name        = "${var.name_prefix}-job-completion-dlq-delivery-failed"
  alarm_description = "EventBridge could not preserve an undelivered completion event in its DLQ."

  namespace           = "AWS/Events"
  metric_name         = "InvocationsFailedToBeSentToDlq"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { RuleName = aws_cloudwatch_event_rule.broker_completion[0].name }
  alarm_actions       = [var.alarm_topic_arn]

  tags = {
    Name        = "${var.name_prefix}-job-completion-dlq-delivery-failed"
    Environment = var.environment
    Terraform   = "true"
  }
}