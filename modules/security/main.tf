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

# ENABLE 'BLOCK PUBLIC SHARING' ON SSM DOCUMENTS
resource "aws_ssm_service_setting" "block_ssm_doc_public_sharing" {
  setting_id    = "/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
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

# INSPECTOR RESOURCES
## ENABLE INSPECTORv2
resource "aws_inspector2_enabler" "main" {
  account_ids = [var.account_id]
  resource_types = [
    "EC2",
    "LAMBDA",
    "LAMBDA_CODE"
  ]
}

## SUBSCRIBE SECURITY HUB TO AMAZON INSPECTOR PRODUCT
resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:aws:securityhub:${var.primary_region}::product/aws/inspector"
  depends_on  = [aws_securityhub_account.main]
}

## ALERT ON HIGH/CRITICAL INSPECTOR FINDINGS VIA SECURITY HUB
resource "aws_cloudwatch_event_rule" "securityhub_inspector_high_critical" {
  name           = "securityhub-inspector-high-critical"
  description    = "Alert on HIGH/CRITICAL Inspector findings in Security Hub"
  event_bus_name = var.secops_event_bus_name

  event_pattern = jsonencode({
    source      = ["aws.securityhub"],
    detail-type = ["Security Hub Findings - Imported"],
    detail = {
      findings = {
        ProductName = ["Inspector"],
        Severity    = { Label = ["HIGH", "CRITICAL"] },
        RecordState = ["ACTIVE"]
      }
    }
  })
}

## EVENT TARGET TO SEND SNS NOTIFICATION
resource "aws_cloudwatch_event_target" "securityhub_inspector_high_critical_to_sns" {
  event_bus_name = var.secops_event_bus_name
  rule           = aws_cloudwatch_event_rule.securityhub_inspector_high_critical.name
  target_id      = "send-to-sns"
  arn            = var.secops_topic_arn
}

# KMS
## KMS KEY FOR LOGS
resource "aws_kms_key" "logs" {
  description             = "CMK for centralized logging (CloudTrail, Config, Flow Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  lifecycle {
    prevent_destroy = false # CHANGE THIS IN PROD
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      ### ALLOW FULL ACCESS FOR ROOT ACCOUNT
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      ### ALLOW CLOUDTRAIL
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
      ### ALLOW AWS CONFIG
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
      ### ALLOW AWS CONFIG SERVICE LINKED ROLE
      {
        Sid    = "AllowConfig"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      ### ALLOW VPC FLOW LOGS / CLOUDWATCH LOGS
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
      ### ALLOW S3
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
      ### ALLOW SNS
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
        Sid    = "AllowCloudwatchAlarms"
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
      },
      ### ALLOW KINESIS FIREHOSE
      {
        Sid    = "AllowKinesisFirehose"
        Effect = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:firehose:${var.primary_region}:${var.account_id}:deliverystream/*"
          }
        }
      },
      ### ALLOW INSPECTORv2
      {
        Sid    = "AllowInspectorDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:role/aws-service-role/inspector2.amazonaws.com/AWSServiceRoleForAmazonInspector2"
        }
        Action = [
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
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

  lifecycle {
    prevent_destroy = false # CHANGE THIS IN PROD
  }

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

# KMS KEY FOR LAMBDA
resource "aws_kms_key" "lambda" {
  description             = "CMK for Lambda environment variable encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ROOT/ADMIN
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # ALLOW LAMBDA SERVICE TO USE THE KEY FOR ENV VAR ENCRYPTION
      {
        Sid    = "AllowLambdaUse"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      }
    ]
  })
  tags = {
    Name      = "lambda-cmk"
    Terraform = "true"
  }
}

## ALIAS FOR LAMBDA KMS KEY
resource "aws_kms_alias" "lambda" {
  name          = "alias/lambda-cmk"
  target_key_id = aws_kms_key.lambda.id
}

# CONFIG BASELINE MODULE
module "config_baseline" {
  source = "./config_baseline"

  config_enabled               = var.config_enabled
  config_role_arn              = var.config_role_arn
  compliance_topic_arn         = var.compliance_topic_arn
  config_remediation_role_arn  = var.config_remediation_role_arn
  centralized_logs_bucket_name = var.centralized_logs_bucket_name
  logs_kms_key_arn             = aws_kms_key.logs.arn
  enable_rules                 = var.enable_rules
}

# TAMPER DETECTION MODULE
module "tamper_detection" {
  source = "./tamper_detection"

  alert_topic_arn = var.secops_topic_arn
}