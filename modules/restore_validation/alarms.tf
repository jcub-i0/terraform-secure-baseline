# ============================================================
# RESTORE VALIDATION — CLOUDWATCH ALARMS
# ============================================================

locals {
  restore_validation_lambda_functions = {
    coordinator = aws_lambda_function.coordinator.function_name
    worker      = aws_lambda_function.worker.function_name
  }

  restore_validation_metric_namespace = "${var.name_prefix}/RestoreValidation"
}

# ------------------------------------------------------------
# SQS DLQ — AT LEAST ONE VISIBLE MESSAGE
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "validation_dlq_messages" {
  alarm_name = "${var.name_prefix}-restore-validation-dlq-messages"

  alarm_description = (
    "Restore Validation DLQ contains messages requiring investigation."
  )

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  statistic   = "Maximum"

  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.validation_dlq.name
  }

  alarm_actions = [var.secops_topic_arn]

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-DLQ-Alarm"
    Environment = var.environment
    Terraform   = "true"
  }
}

# ------------------------------------------------------------
# COORDINATOR AND WORKER — LAMBDA ERRORS
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.restore_validation_lambda_functions

  alarm_name = "${var.name_prefix}-restore-validation-${each.key}-errors"

  alarm_description = (
    "Restore Validation ${each.key} Lambda reported an execution error."
  )

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"

  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = [var.secops_topic_arn]

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-${each.key}-Errors"
    Environment = var.environment
    Terraform   = "true"
  }
}

# ------------------------------------------------------------
# DEFINITIVE SQL VALIDATION FAILURE — LOG METRIC
# ------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "validation_failed" {
  name = "${var.name_prefix}-restore-validation-failed"

  log_group_name = aws_cloudwatch_log_group.coordinator.name

  # Matches coordinator.py's successful submission of a
  # definitive FAILED validation result to AWS Backup.
  pattern = "\"validation submitted: FAILED\""

  metric_transformation {
    name      = "FailedValidations"
    namespace = local.restore_validation_metric_namespace
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "validation_failed" {
  alarm_name = "${var.name_prefix}-restore-validation-failed"

  alarm_description = (
    "Restore Validation submitted a definitive FAILED result to AWS Backup."
  )

  namespace   = local.restore_validation_metric_namespace
  metric_name = "FailedValidations"
  statistic   = "Sum"

  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.secops_topic_arn]

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Failed"
    Environment = var.environment
    Terraform   = "true"
  }
}