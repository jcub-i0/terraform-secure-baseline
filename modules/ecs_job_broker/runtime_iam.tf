data "aws_region" "current" {}

data "aws_iam_policy_document" "broker_runtime" {
  count = length(var.jobs) > 0 ? 1 : 0

  statement {
    sid    = "ConsumeBrokerRequests"
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = [
      aws_sqs_queue.broker_requests[0].arn
    ]
  }

  statement {
    sid       = "DecryptBrokerRequests"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.broker_request_queue_cmk_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "AccessExecutionLedger"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:ConditionCheckItem"
    ]

    resources = [
      aws_dynamodb_table.execution_ledger[0].arn
    ]
  }

  statement {
    sid    = "UseExecutionLedgerCMK"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [var.execution_ledger_cmk_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["dynamodb.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "WriteBrokerLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${aws_cloudwatch_log_group.broker[0].arn}:*"
    ]
  }

  dynamic "statement" {
    for_each = var.admission_gate == null ? [] : [var.admission_gate]

    content {
      sid    = "ReadAdmissionGate"
      effect = "Allow"
      actions = [
        "dynamodb:GetItem",
        "dynamodb:ConditionCheckItem"
      ]
      resources = [statement.value.table_arn]
    }
  }

  dynamic "statement" {
    for_each = var.admission_gate == null ? [] : [var.admission_gate]

    content {
      sid       = "DecryptAdmissionGate"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value.cmk_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["dynamodb.${split(":", statement.value.table_arn)[3]}.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:aws:dynamodb:tableName"
        values   = [split("/", statement.value.table_arn)[1]]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:aws:dynamodb:subscriberId"
        values   = [split(":", statement.value.table_arn)[4]]
      }
    }
  }

  dynamic "statement" {
    for_each = var.completion_delivery == null ? [] : [var.completion_delivery]
    content {
      sid       = "ConsumeBrokerCompletion"
      effect    = "Allow"
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      resources = [aws_sqs_queue.broker_completion[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.completion_delivery == null ? [] : [var.completion_delivery]
    content {
      sid       = "DecryptBrokerCompletion"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value.queue_cmk_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["sqs.${data.aws_region.current.region}.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:aws:sqs:arn"
        values   = [aws_sqs_queue.broker_completion[0].arn]
      }
    }
  }
}

resource "aws_iam_role_policy" "broker_runtime" {
  count = length(var.jobs) > 0 ? 1 : 0

  name   = "${var.name_prefix}-broker-runtime"
  role   = aws_iam_role.broker_execution[0].id
  policy = data.aws_iam_policy_document.broker_runtime[0].json
}
