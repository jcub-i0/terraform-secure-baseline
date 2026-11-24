
resource "aws_sqs_queue" "broker_requests" {
  count = length(var.jobs) > 0 ? 1 : 0

  name = "${var.name_prefix}-job-broker-requests"

  # Standard queue; durable deduplication belongs to DynamoDB.
  fifo_queue = false

  # Application-owned customer-managed KMS key.
  kms_master_key_id = var.broker_request_queue_cmk_arn

  # Initial target: Lambda timeout <= 30 seconds.
  # Reconcile with the Lambda configuration in I2-C.
  visibility_timeout_seconds = 180

  # Four-day request retention.
  message_retention_seconds = 345600

  tags = {
    Name        = "${var.name_prefix}-job-broker-requests"
    Environment = var.environment
    Terraform   = "true"
  }
}

# Deny requests made without TLS.
data "aws_iam_policy_document" "broker_queue_transport" {
  count = length(var.jobs) > 0 ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.broker_requests[0].arn]

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
}

resource "aws_sqs_queue_policy" "broker_requests" {
  count = length(var.jobs) > 0 ? 1 : 0

  queue_url = aws_sqs_queue.broker_requests[0].url
  policy    = data.aws_iam_policy_document.broker_queue_transport[0].json
}
