data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# KMS
## KMS KEY FOR LOGS
resource "aws_kms_key" "logs" {
  description             = "CMK for centralized logging (CloudTrail, Config, Flow Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      ### FULL ACCESS FOR ROOT ACCOUNT
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },

      ### CLOUDTRAIL
      {
        Sid    = "AllowCloudTrail"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazon.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      ### AWS CONFIG
      {
        Sid    = "AllowConfig"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
      },

      ### VPC FLOW LOGS / CLOUDWATCH LOGS
      {
        Sid    = "AllowLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },

      ### ALLOW S3 TO USE THE KEY
      {
        Sid    = "AllowS3UseOfKey"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazon.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "ksm:ReEncrypt",
          "ksm:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name      = "logs-cmk"
    Terraform = "true"
  }
}

## ALIAS FOR LOGS KMS KEY
resource "aws_kms_alias" "logs" {
  name          = "alias/tf-baseline-logs"
  target_key_id = aws_kms_key.logs.key_id
}