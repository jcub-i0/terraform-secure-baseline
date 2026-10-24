# =============================================================================
# RESTORE VALIDATION — IAM
# =============================================================================

data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# Lambda execution role trust policy
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "restore_lambda_assume_role" {
  statement {
    sid     = "AllowLambdaService"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# =============================================================================
# COORDINATOR LAMBDA
# =============================================================================

resource "aws_iam_role" "coordinator" {
  name               = "${var.name_prefix}-restore-validation-coordinator"
  description        = "Coordinates AWS Backup RDS restore validation"
  assume_role_policy = data.aws_iam_policy_document.restore_lambda_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Coordinator"
    Environment = var.environment
    Terraform   = "true"
  }
}

# CloudWatch Logs permissions for the non-VPC coordinator
resource "aws_iam_role_policy_attachment" "coordinator_logs" {
  role = aws_iam_role.coordinator.name

  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "coordinator" {

  # AWS Backup job discovery and validation reporting
  # These actions do not support resource-level ARN restrictions
  statement {
    sid    = "RestoreJobValidation"
    effect = "Allow"

    actions = [
      "backup:DescribeRestoreJob",
      "backup:PutRestoreValidationResult"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.primary_region]
    }
  }

  # Discover the endpoint and metadata of a restored RDS instance
  statement {
    sid    = "DescribeRestoredRDS"
    effect = "Allow"

    actions = [
      "rds:DescribeDBInstances"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:rds:${var.primary_region}:${var.account_id}:db:*"
    ]
  }

  # Invoke only this module's SQL validation worker
  statement {
    sid    = "InvokeRestoreValidationWorker"
    effect = "Allow"

    actions = [
      "lambda:InvokeFunction"
    ]

    resources = [
      aws_lambda_function.worker.arn
    ]
  }

  # Deliver failed asynchronous invocations to the validation DLQ
  statement {
    sid    = "SendValidationFailuresToDLQ"
    effect = "Allow"

    actions = [
      "sqs:SendMessage"
    ]

    resources = [
      aws_sqs_queue.validation_dlq.arn
    ]
  }

  # Decrypt Lambda environment configuration encrypted by the baseline CMK
  statement {
    sid    = "DecryptLambdaEnvironment"
    effect = "Allow"

    actions = [
      "kms:Decrypt"
    ]

    resources = [
      var.lambda_cmk_arn
    ]
  }
}

resource "aws_iam_role_policy" "coordinator" {
  name   = "${var.name_prefix}-restore-validation-coordinator-policy"
  role   = aws_iam_role.coordinator.name
  policy = data.aws_iam_policy_document.coordinator.json
}

# =============================================================================
# SQL VALIDATION WORKER LAMBDA
# =============================================================================

resource "aws_iam_role" "worker" {
  name               = "${var.name_prefix}-restore-validation-worker"
  description        = "Executes private PostgreSQL restore-integrity checks"
  assume_role_policy = data.aws_iam_policy_document.restore_lambda_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-Restore-Validation-Worker"
    Environment = var.environment
    Terraform   = "true"
  }
}

# Provides Lambda VPC ENI permissions and CloudWatch Logs permissions
resource "aws_iam_role_policy_attachment" "worker_vpc" {
  role = aws_iam_role.worker.name

  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "worker" {

  # Retrieve only the approved read-only PostgreSQL credential secret
  statement {
    sid    = "ReadValidationCredentials"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      var.restore_validation_secret_arn
    ]
  }

  # Permit decrypting that secret only through Secrets Manager
  statement {
    sid    = "DecryptValidationCredentials"
    effect = "Allow"

    actions = [
      "kms:Decrypt"
    ]

    resources = [
      var.secrets_manager_cmk_arn
    ]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.primary_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [var.restore_validation_secret_arn]
    }
  }

  # Decrypt Lambda environment configuration encrypted by the baseline CMK.
  statement {
    sid    = "DecryptLambdaEnvironment"
    effect = "Allow"

    actions = [
      "kms:Decrypt"
    ]

    resources = [
      var.lambda_cmk_arn
    ]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "${var.name_prefix}-restore-validation-worker-policy"
  role   = aws_iam_role.worker.name
  policy = data.aws_iam_policy_document.worker.json
}
