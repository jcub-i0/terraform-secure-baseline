
resource "aws_lambda_function" "broker" {
  count = (
    length(var.jobs) > 0 &&
    var.broker_lambda_package != null
  ) ? 1 : 0

  function_name = "${var.name_prefix}-job-broker"
  description   = "Protected standalone ECS job admission broker"

  role         = aws_iam_role.broker_execution[0].arn
  package_type = "Zip"

  runtime       = "python3.12"
  handler       = "broker.lambda_handler"
  architectures = ["x86_64"]

  s3_bucket         = var.broker_lambda_package.bucket
  s3_key            = var.broker_lambda_package.key
  s3_object_version = var.broker_lambda_package.version_id

  timeout     = 30
  memory_size = 256

  # No invocations until runtime admission and lifecycle controls have been implemented and approved
  reserved_concurrent_executions = 0

  kms_key_arn = var.broker_lambda_cmk_arn

  environment {
    variables = {
      BROKER_QUEUE_URL      = aws_sqs_queue.broker_requests[0].url
      EXECUTION_LEDGER_NAME = aws_dynamodb_table.execution_ledger[0].name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.broker,
    aws_iam_role_policy.broker_runtime,
    aws_iam_role_policy.broker_assume_launchers
  ]

  tags = {
    Name        = "${var.name_prefix}-job-broker"
    Environment = var.environment
    Terraform   = "true"
  }
}
