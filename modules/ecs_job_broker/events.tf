resource "aws_cloudwatch_event_rule" "broker_completion" {
  count = local.completion_enabled ? 1 : 0

  name           = "${var.name_prefix}-job-broker-completion"
  description    = "Stopped ECS tasks from this application's approved job families."
  event_bus_name = "default"

  # Activation requires protected deployment/invocation controls and qualification.
  state = "DISABLED"

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    account       = [split(":", var.approved_cluster_arn)[4]]
    region        = [split(":", var.approved_cluster_arn)[3]]
    detail = {
      clusterArn = [var.approved_cluster_arn]
      lastStatus = ["STOPPED"]
      taskDefinitionArn = [
        for family_arn in sort(tolist(var.completion_delivery.task_definition_family_arns)) :
        { prefix = "${family_arn}:" }
      ]
    }
  })

  tags = {
    Name        = "${var.name_prefix}-job-broker-completion"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_cloudwatch_event_target" "broker_completion" {
  count = local.completion_enabled ? 1 : 0

  rule           = aws_cloudwatch_event_rule.broker_completion[0].name
  event_bus_name = "default"
  target_id      = "broker-completion"
  arn            = aws_sqs_queue.broker_completion[0].arn

  # Preserve the complete ECS event; do not synthesize completion evidence.
  dead_letter_config {
    arn = aws_sqs_queue.broker_completion_dlq["delivery"].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }

  depends_on = [aws_sqs_queue_policy.broker_completion]
}
