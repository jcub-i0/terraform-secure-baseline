resource "aws_cloudwatch_metric_alarm" "broker_processing_dlq_visible" {
  count = length(var.jobs) > 0 ? 1 : 0

  alarm_name = "${var.name_prefix}-broker-processing-dlq-messages"

  alarm_description = "Failed broker requests are present in the processing DLQ."

  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  treat_missing_data = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.broker_processing_dlq[0].name
  }

  alarm_actions = [var.alarm_topic_arn]

  tags = {
    Name        = "${var.name_prefix}-broker-processing-dlq-messages"
    Environment = var.environment
    Terraform   = "true"
  }
}
