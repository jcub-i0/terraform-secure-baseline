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
}

resource "aws_iam_role_policy" "broker_runtime" {
  count = length(var.jobs) > 0 ? 1 : 0

  name   = "${var.name_prefix}-broker-runtime"
  role   = aws_iam_role.broker_execution[0].id
  policy = data.aws_iam_policy_document.broker_runtime[0].json
}
