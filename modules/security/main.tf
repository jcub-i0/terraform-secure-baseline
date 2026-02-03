locals {
  # SecurityHub standards for securityhub_standards_subscriptions resource to loop through
  ## Select the SecurityHub standards you want by uncommenting the respective standard(s)
  securityhub_standards = {
    aws_fsbp = "arn:aws:securityhub:${var.primary_region}::standards/aws-foundational-security-best-practices/v/1.0.0",
    #aws_tagging = "arn:aws:securityhub:${var.primary_region}::standards/aws-resource-tagging-standard/v/1.0.0",
    #cis = "arn:aws:securityhub:${var.primary_region}::standards/cis-aws-foundations-benchmark/v/5.0.0",
    #nist_800 = "arn:aws:securityhub:${var.primary_region}::standards/nist-800-53/v/5.0.0",
    #pci_dss = "arn:aws:securityhub:${var.primary_region}::standards/pci-dss/v/4.0.1"
  }
}

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

/*resource "aws_config_configuration_recorder_status" "config_rec_state" {
  name = aws_config_configuration_recorder.config.name
  is_enabled = true
}*/

## DELIVERY CHANNEL
resource "aws_config_delivery_channel" "config" {
  s3_bucket_name = var.centralized_logs_bucket_name
  s3_key_prefix  = "Config"
  s3_kms_key_arn = aws_kms_key.logs.arn
  sns_topic_arn  = var.compliance_topic_arn

  depends_on = [
    aws_config_configuration_recorder.config
  ]
}

## CONFIGURATION RECORDER STATUS
resource "aws_config_configuration_recorder_status" "config" {
  name       = aws_config_configuration_recorder.config.name
  is_enabled = true

  depends_on = [
    aws_config_delivery_channel.config
  ]
}

# CONFIG REMEDIATIONS
## S3 PUBLIC ACCESS BLOCK CONFIG REMEDIATION
### S3 PUBLIC ACCESS REMEDIATION RULE
resource "aws_config_config_rule" "s3_public_access_block" {
  name = "s3-bucket-public-read-block"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
  }
}

### REMEDIATION TO AUTOMATICALLY DISABLE S3 PUBLIC READ AND WRITE
resource "aws_config_remediation_configuration" "s3_public_access_block" {
  config_rule_name           = aws_config_config_rule.s3_public_access_block.name
  resource_type              = "AWS::S3::Bucket"
  target_type                = "SSM_DOCUMENT"
  target_id                  = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = var.config_remediation_role_arn
  }

  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }
}

## EC2 PUBLIC IP CONFIG REMEDIATION
### REMEDIATION RULE FOR EC2 INSTANCES WITH PUBLIC IP ADDRESSES
resource "aws_config_config_rule" "ec2_no_public_ip" {
  name = "ec2-no-public-ip"

  source {
    owner             = "AWS"
    source_identifier = "EC2_INSTANCE_NO_PUBLIC_IP"
  }
}

# GUARDDUTY
resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  region                       = var.primary_region
}

## LOOP THROUGH EACH FEATURE LISTED IN 'var.guardduty_features'
resource "aws_guardduty_detector_feature" "main" {
  for_each    = toset(var.guardduty_features)
  detector_id = aws_guardduty_detector.main.id
  name        = each.value
  status      = "ENABLED"

  lifecycle {
    ignore_changes = [
      additional_configuration,
      status
    ]
  }
}

# SECURITY HUB
resource "aws_securityhub_account" "main" {
  depends_on = [aws_guardduty_detector.main]
}

## SUBSCRIBE TO EACH SECURITY HUB STANDARD LISTED IN 'local.securityhub_standards'
resource "aws_securityhub_standards_subscription" "main" {
  for_each      = local.securityhub_standards
  standards_arn = each.value
  depends_on    = [aws_securityhub_account.main]
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
          AWS = "arn:aws:iam::${var.account_id}:root"
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
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${var.account_id}:trail/*"
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
          Service = "logs.${var.current_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      ### ALLOW S3 TO USE THE KEY
      {
        Sid    = "AllowS3"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      },
      ### ALLOW SNS TO USE THE KEY
      {
        Sid    = "AllowSns"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      ### ALLOW CLOUDWATCH ALARMS
      {
        Sid = "AllowCloudwatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
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

### ALIAS FOR LOGS KMS KEY
resource "aws_kms_alias" "logs" {
  name          = "alias/tf-baseline-logs"
  target_key_id = aws_kms_key.logs.key_id
}

## EBS KMS KEY
resource "aws_kms_key" "ebs" {
  description             = "CMK for encrypting EBS volumes and snapshots"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # FULL ACCESS FOR ROOT ACCOUNT
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # ALLOW EC2/EBS
      {
        Sid    = "AllowEc2Ebs"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name      = "EBS-CMK"
    Terraform = "true"
  }
}

### EBS KMS KEY ALIAS
resource "aws_kms_alias" "ebs" {
  name          = "alias/ebs-cmk"
  target_key_id = aws_kms_key.ebs.id
}