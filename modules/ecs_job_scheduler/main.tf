data "aws_caller_identity" "current" {
  count = length(var.schedules) > 0 ? 1 : 0
}

resource "aws_scheduler_schedule_group" "jobs" {
  count = length(var.schedules) > 0 ? 1 : 0

  name = "${var.name_prefix}-job-schedules"

  tags = {
    Name        = "${var.name_prefix}-job-schedules"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_sqs_queue" "scheduler_dlq" {
  for_each = var.schedules

  name = "${var.name_prefix}-${each.key}-scheduler-dlq"

  kms_master_key_id = var.dlq_kms_key_arn

  # Maximum SQS retention period: 14 days.
  message_retention_seconds = 1209600

  tags = {
    Name        = "${var.name_prefix}-${each.key}-scheduler-dlq"
    Environment = var.environment
    Terraform   = "true"
  }
}

data "aws_iam_policy_document" "scheduler_assume_role" {
  for_each = var.schedules

  statement {
    sid     = "AllowSchedulerAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current[0].account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_scheduler_schedule_group.jobs[0].arn]
    }
  }
}

resource "aws_iam_role" "scheduler_execution" {
  for_each = var.schedules

  name = "${var.name_prefix}-${each.key}-scheduler-execution"

  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role[each.key].json

  tags = {
    Name        = "${var.name_prefix}-${each.key}-scheduler-execution"
    Environment = var.environment
    Terraform   = "true"
  }
}

data "aws_iam_policy_document" "scheduler_delivery" {
  for_each = var.schedules

  statement {
    sid       = "SendBrokerRequest"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [var.broker_request_queue_arn]
  }

  statement {
    sid       = "SendFailureToDLQ"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.scheduler_dlq[each.key].arn]
  }

  statement {
    sid    = "UseEncryptedSQSQueues"
    effect = "Allow"

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt"
    ]

    resources = distinct(compact([
      var.dlq_kms_key_arn,
      var.broker_request_queue_kms_key_arn
    ]))
  }
}

resource "aws_iam_role_policy" "scheduler_delivery" {
  for_each = var.schedules

  name   = "${var.name_prefix}-${each.key}-scheduler-delivery"
  role   = aws_iam_role.scheduler_execution[each.key].id
  policy = data.aws_iam_policy_document.scheduler_delivery[each.key].json
}

resource "aws_scheduler_schedule" "jobs" {
  for_each = var.schedules

  name        = "${var.name_prefix}-${each.key}"
  description = "Application job schedule for ${each.value.job_key}"

  group_name                   = aws_scheduler_schedule_group.jobs[0].name
  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = each.value.timezone

  state = each.value.enabled ? "ENABLED" : "DISABLED"

  action_after_completion = "NONE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.broker_request_queue_arn
    role_arn = aws_iam_role.scheduler_execution[each.key].arn

    input = jsonencode({
      schema_version = 1
      job_key        = each.value.job_key
      schedule_key   = each.key
      schedule_arn   = "<aws.scheduler.schedule-arn>"
      scheduled_time = "<aws.scheduler.scheduled-time>"

      request_key = "<aws.scheduler.schedule-arn>|<aws.scheduler.scheduled-time>"
    })

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq[each.key].arn
    }

    retry_policy {
      maximum_retry_attempts       = each.value.maximum_retry_attempts
      maximum_event_age_in_seconds = each.value.maximum_event_age_in_seconds
    }
  }

  depends_on = [
    aws_iam_role_policy.scheduler_delivery
  ]
}
