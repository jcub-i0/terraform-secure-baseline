
# =============================================================================
# RESTORE VALIDATION — MAIN
# =============================================================================

# =============================================================================
# X-RAY IAM ATTACHMENTS
# =============================================================================

resource "aws_iam_role_policy_attachment" "coordinator_xray" {
  role       = aws_iam_role.coordinator.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "worker_xray" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# =============================================================================
# CLOUDWATCH LOG GROUPS
# =============================================================================

resource "aws_cloudwatch_log_group" "coordinator" {
  name              = "/aws/lambda/${var.name_prefix}-restore-validation-coordinator"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Coordinator-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${var.name_prefix}-restore-validation-worker"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Worker-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

# =============================================================================
# FAILURE DEAD-LETTER QUEUE
# =============================================================================

resource "aws_sqs_queue" "validation_dlq" {
  name                      = "${var.name_prefix}-restore-validation-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-DLQ"
    Environment = var.environment
    Terraform   = "true"
  }
}

# =============================================================================
# SQL VALIDATION WORKER LAMBDA
# =============================================================================

data "archive_file" "worker" {
  type             = "zip"
  source_dir       = "${path.module}/lambda/build/worker"
  output_path      = "${path.module}/lambda/worker.zip"
  output_file_mode = "0644"
}

resource "aws_lambda_function" "worker" {
  function_name = "${var.name_prefix}-restore-validation-worker"
  description   = "Verify synthetic-data integrity on a private restored RDS instance"

  role          = aws_iam_role.worker.arn
  handler       = "worker.lambda_handler"
  runtime       = "python3.12"
  architectures = ["x86_64"]

  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256

  timeout                        = 120
  memory_size                    = 512
  reserved_concurrent_executions = 2
  kms_key_arn                    = var.lambda_cmk_arn

  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.worker_subnet_ids
    security_group_ids = [aws_security_group.worker.id]
  }

  environment {
    variables = {
      VALIDATION_SECRET_ARN = var.restore_validation_secret_arn
      DB_NAME               = var.db_name
      DB_PORT               = tostring(var.db_port)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.worker,
    aws_iam_role_policy.worker,
    aws_iam_role_policy_attachment.worker_vpc,
    aws_iam_role_policy_attachment.worker_xray,
  ]

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Worker"
    Environment = var.environment
    Terraform   = "true"
  }
}

# =============================================================================
# RESTORE VALIDATION COORDINATOR LAMBDA
# =============================================================================

data "archive_file" "coordinator" {
  type             = "zip"
  source_file      = "${path.module}/lambda/coordinator.py"
  output_path      = "${path.module}/lambda/coordinator.zip"
  output_file_mode = "0644"
}

resource "aws_lambda_function" "coordinator" {
  #checkov:skip=CKV_AWS_117:Coordinator intentionally runs outside VPC for AWS control-plane API access; it has no direct database access.
  #checkov:skip=CKV_AWS_116:Async execution errors use an on-failure SQS destination; EventBridge delivery uses its own DLQ configuration.

  function_name = "${var.name_prefix}-restore-validation-coordinator"
  description   = "Coordinate and report AWS Backup RDS restore integrity validation"

  role          = aws_iam_role.coordinator.arn
  handler       = "coordinator.lambda_handler"
  runtime       = "python3.12"
  architectures = ["x86_64"]

  filename         = data.archive_file.coordinator.output_path
  source_code_hash = data.archive_file.coordinator.output_base64sha256

  # The coordinator synchronously invokes the worker (120s timeout).
  timeout                        = 180
  memory_size                    = 256
  reserved_concurrent_executions = 2
  kms_key_arn                    = var.lambda_cmk_arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      EXPECTED_ACCOUNT_ID            = var.account_id
      EXPECTED_REGION                = var.primary_region
      RESTORE_TESTING_PLAN_ARN       = var.restore_testing_plan_arn
      SOURCE_RDS_ARN                 = var.source_rds_arn
      EXPECTED_RESTORE_TEST_DB_SG_ID = var.restore_test_db_sg_id
      EXPECTED_VPC_ID                = var.vpc_id
      WORKER_FUNCTION_NAME           = aws_lambda_function.worker.function_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.coordinator,
    aws_iam_role_policy.coordinator,
    aws_iam_role_policy_attachment.coordinator_logs,
    aws_iam_role_policy_attachment.coordinator_xray,
  ]

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Coordinator"
    Environment = var.environment
    Terraform   = "true"
  }
}

# =============================================================================
# EVENTBRIDGE — COMPLETED RDS RESTORE TESTING JOBS
# =============================================================================

resource "aws_cloudwatch_event_rule" "restore_completed" {
  name        = "${var.name_prefix}-restore-validation-completed"
  description = "Completed RDS restore jobs for the configured Restore Testing plan"

  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Restore Job State Change"]

    account = [var.account_id]
    region  = [var.primary_region]

    detail = {
      status                = ["COMPLETED"]
      resourceType          = ["RDS"]
      restoreTestingPlanArn = [var.restore_testing_plan_arn]
    }
  })

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Completed"
    Environment = var.environment
    Terraform   = "true"
  }
}

# =============================================================================
# EVENTBRIDGE -> COORDINATOR INVOCATION PERMISSION
# =============================================================================

resource "aws_lambda_permission" "eventbridge_coordinator" {
  statement_id   = "AllowEventBridgeRestoreValidation"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.coordinator.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.restore_completed.arn
  source_account = var.account_id
}

# =============================================================================
# EVENTBRIDGE DLQ RESOURCE POLICY
# =============================================================================

data "aws_iam_policy_document" "validation_dlq" {
  statement {
    sid    = "AllowEventBridgeRestoreValidationDLQ"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = [
      "sqs:SendMessage"
    ]

    resources = [
      aws_sqs_queue.validation_dlq.arn
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.restore_completed.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "validation_dlq" {
  queue_url = aws_sqs_queue.validation_dlq.id
  policy    = data.aws_iam_policy_document.validation_dlq.json
}

# =============================================================================
# EVENTBRIDGE TARGET
# =============================================================================

resource "aws_cloudwatch_event_target" "coordinator" {
  rule      = aws_cloudwatch_event_rule.restore_completed.name
  target_id = "RestoreValidationCoordinator"
  arn       = aws_lambda_function.coordinator.arn

  dead_letter_config {
    arn = aws_sqs_queue.validation_dlq.arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 1800
    maximum_retry_attempts       = 3
  }

  depends_on = [
    aws_lambda_permission.eventbridge_coordinator,
    aws_sqs_queue_policy.validation_dlq,
  ]
}

# =============================================================================
# COORDINATOR ASYNCHRONOUS EXECUTION FAILURE HANDLING
# =============================================================================

resource "aws_lambda_function_event_invoke_config" "coordinator" {
  function_name = aws_lambda_function.coordinator.function_name

  maximum_event_age_in_seconds = 1800
  maximum_retry_attempts       = 1

  destination_config {
    on_failure {
      destination = aws_sqs_queue.validation_dlq.arn
    }
  }
}
