# SHARED POLICIES ATTACHED TO MULTIPLE ROLES

# GENERIC POLICY TO ALLOW READ ACCESS TO CENTRALIZED LOGS S3 BUCKET
data "aws_iam_policy_document" "logs_s3_readonly" {
  statement {
    sid    = "ListCentralizedLogsBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [var.centralized_logs_bucket_arn]
  }

  statement {
    sid    = "ReadCentralizedLogsObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging",
      "s3:GetObjectVersionTagging"
    ]

    resources = ["${var.centralized_logs_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "logs_s3_readonly" {
  name        = "${var.name_prefix}-CentralizedLogsS3ReadOnly"
  description = "Read-only access to Centralized Logs S3 bucket (no delete, no write)"
  policy      = data.aws_iam_policy_document.logs_s3_readonly
}

# GENERIC POLICY TO ALLOW DECRYPTION OF OBJECTS ENCRYPTED WITH THE LOGS CMK
resource "aws_iam_policy" "logs_cmk_decrypt" {
  name        = "${var.name_prefix}-LogsKmsDecrypt"
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