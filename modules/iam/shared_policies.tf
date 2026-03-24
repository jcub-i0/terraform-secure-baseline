# SHARED POLICIES ATTACHED TO MULTIPLE ROLES
## GENERIC POLICY TO ALLOW READ ACCESS TO CENTRALIZED LOGS S3 BUCKET
resource "aws_iam_policy" "logs_s3_readonly" {
  name        = "CentralizedLogsS3ReadOnly"
  description = "Read-only access to Centralized Logs S3 bucket (no delete, no write)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # LIST BUCKET + READ BUCKET METADATA
      {
        Sid    = "ListCentralizedLogsBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = var.centralized_logs_bucket_arn
      },
      # READ OBJECTS + VERSIONS
      {
        Sid    = "ReadCentralizedLogsObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${var.centralized_logs_bucket_arn}/*"
      }
    ]
  })
}

## GENERIC POLICY TO ALLOW DECRYPTION OF OBJECTS ENCRYPTED WITH THE LOGS CMK
resource "aws_iam_policy" "logs_cmk_decrypt" {
  name        = "LogsKmsDecrypt"
  description = "Allow decryption of objects encrypted with the Logs CMK"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDecryptLogsKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.logs_cmk_arn
      }
    ]
  })
}

### EC2 ROLLBACK TRIGGER POLICY
resource "aws_iam_policy" "secops_rollback_trigger" {
  name = "SecOpsRollbackTriggerPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEc2RollbackEventOnly"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = "arn:aws:events:${var.primary_region}:${var.account_id}:event-bus/security-operations-bus"
      }
    ]
  })
}