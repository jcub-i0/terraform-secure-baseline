data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# CONFIG
## CONFIGURATION RECORDER
resource "aws_config_configuration_recorder" "config" {
  name     = "tf-secure-baseline"
  role_arn = var.config_role_arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

## DELIVERY CHANNEL
resource "aws_config_delivery_channel" "config" {
  s3_bucket_name = var.centralized_logs_bucket_name
  s3_key_prefix  = "config"
  s3_kms_key_arn = aws_kms_key.logs.arn
  # sns_topic_arn = 

  depends_on = [aws_config_configuration_recorder.config]
}

## CONFIGURATION RECORDER STATUS
resource "aws_config_configuration_recorder_status" "config" {
  name       = aws_config_configuration_recorder.config.name
  is_enabled = true
}

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
          Service = "cloudtrail.amazonaws.com"
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
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
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
          Service = "s3.amazonaws.com"
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