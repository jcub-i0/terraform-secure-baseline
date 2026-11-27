resource "aws_sqs_queue" "broker_completion" {
  count = local.completion_enabled ? 1 : 0

  name                       = "${var.name_prefix}-job-broker-completion"
  fifo_queue                 = false
  kms_master_key_id          = var.completion_delivery.queue_cmk_arn
  visibility_timeout_seconds = 360
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.broker_completion_dlq["processing"].arn
    maxReceiveCount     = 5
  })

  tags = {
    Name        = "${var.name_prefix}-job-broker-completion"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_sqs_queue" "broker_completion_dlq" {
  for_each = local.completion_enabled ? toset(["delivery", "processing"]) : toset([])

  name                      = "${var.name_prefix}-job-completion-${each.key}-dlq"
  fifo_queue                = false
  kms_master_key_id         = var.completion_delivery.queue_cmk_arn
  message_retention_seconds = 1209600

  tags = {
    Name        = "${var.name_prefix}-job-completion-${each.key}-dlq"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "broker_completion_processing" {
  count = local.completion_enabled ? 1 : 0

  queue_url = aws_sqs_queue.broker_completion_dlq["processing"].url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.broker_completion[0].arn]
  })
}

data "aws_iam_policy_document" "broker_completion_queue" {
  for_each = local.completion_queues

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Processing DLQ receives SQS-managed redrive, not EventBridge submissions.
  dynamic "statement" {
    for_each = each.key == "processing" ? [] : [true]
    content {
      sid       = "AllowCompletionRule"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [each.value.arn]

      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }
      condition {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [aws_cloudwatch_event_rule.broker_completion[0].arn]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [split(":", var.approved_cluster_arn)[4]]
      }
    }
  }

  # An allow alone would not block same-account IAM SendMessage grants.
  dynamic "statement" {
    for_each = each.key == "processing" ? [] : [true]
    content {
      sid       = "DenyNonEventBridgeSenders"
      effect    = "Deny"
      actions   = ["sqs:SendMessage"]
      resources = [each.value.arn]

      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "StringNotEqualsIfExists"
        variable = "aws:PrincipalServiceName"
        values   = ["events.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "processing" ? [] : [true]
    content {
      sid       = "DenyOtherCompletionRules"
      effect    = "Deny"
      actions   = ["sqs:SendMessage"]
      resources = [each.value.arn]

      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "ArnNotEqualsIfExists"
        variable = "aws:SourceArn"
        values   = [aws_cloudwatch_event_rule.broker_completion[0].arn]
      }
    }
  }
}

resource "aws_sqs_queue_policy" "broker_completion" {
  for_each = local.completion_queues

  queue_url = each.value.url
  policy    = data.aws_iam_policy_document.broker_completion_queue[each.key].json
}
