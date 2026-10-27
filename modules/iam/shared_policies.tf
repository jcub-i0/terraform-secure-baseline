data "aws_partition" "current" {}

# SHARED POLICIES ATTACHED TO MULTIPLE ROLES

# SHARED READ-ONLY ACCESS TO TERRAFORM-MANAGED S3 LOG BUCKETS
data "aws_iam_policy_document" "logs_s3_readonly" {
  statement {
    sid    = "ListManagedLogBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = compact([
      var.centralized_logs_bucket_arn,
      var.alb_access_logs_bucket_arn,
    ])
  }

  statement {
    sid    = "ReadManagedLogObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging",
      "s3:GetObjectVersionTagging"
    ]

    resources = compact([
      "${var.centralized_logs_bucket_arn}/*",
      var.alb_access_logs_bucket_arn != null
      ? "${var.alb_access_logs_bucket_arn}/alb/*"
      : null
    ])
  }
}

resource "aws_iam_policy" "logs_s3_readonly" {
  name        = "${var.name_prefix}-CentralizedLogsS3ReadOnly"
  description = "Read-only access to Centralized Logs S3 bucket (no delete, no write)"
  policy      = data.aws_iam_policy_document.logs_s3_readonly.json
}

# GENERIC POLICY TO ALLOW DECRYPTION OF OBJECTS ENCRYPTED WITH THE LOGS CMK
data "aws_iam_policy_document" "logs_cmk_decrypt" {
  statement {
    sid    = "AllowDecryptLogsKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]

    resources = [var.logs_cmk_arn]
  }
}

resource "aws_iam_policy" "logs_cmk_decrypt" {
  name        = "${var.name_prefix}-LogsKmsDecrypt"
  description = "Allow decryption of objects encrypted with the Logs CMK"
  policy      = data.aws_iam_policy_document.logs_cmk_decrypt.json
}