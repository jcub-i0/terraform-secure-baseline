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
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
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
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${data.aws_partition.current.partition}:cloudtrail:*:${var.account_id}:trail/*"
          }
        }
      },
      ### ALLOW AWS CONFIG SERVICE LINKED ROLE
      {
        Sid    = "AllowConfigServiceRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      ### ALLOW CONFIG SERVICE PRINCIPAL
      {
        Sid    = "AllowConfigServicePrincipal"
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
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      },
      ### ALLOW VPC FLOW LOGS / CLOUDWATCH LOGS
      {
        Sid    = "AllowLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.primary_region}.amazonaws.com"
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
      {
        Sid    = "AllowSQS"
        Effect = "Allow"
        Principal = {
          Service = "sqs.amazonaws.com"
        },
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      },
      ### ALLOW CLOUDWATCH ALARMS
      {
        Sid    = "AllowCloudwatch"
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
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:firehose:${var.primary_region}:${var.account_id}:deliverystream/*"
          }
        }
      },
      ### ALLOW INSPECTORv2
      {
        Sid    = "AllowInspectorDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:role/aws-service-role/inspector2.amazonaws.com/AWSServiceRoleForAmazonInspector2"
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
      },
      ### ALLOW NETWORK FIREWALL
      {
        Sid    = "AllowFirewallLogDelivery"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      },
      ### ALLOW EVENTBRIDGE
      {
        Sid    = "AllowEventBridgeForSNS"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "${var.name_prefix}-logs-cmk"
    Environment = var.environment
    Terraform   = "true"
  }
}

### ALIAS FOR LOGS KMS KEY
resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name_prefix}/logs-cmk"
  target_key_id = aws_kms_key.logs.key_id
}

## RDS PERFORMANCE/ DATABASE INSIGHTS KMS KEY
# Account-root delegation allows same-account IAM identities, including RDS
# control-plane integrations, to receive grants according to their IAM policies.
# Data readers additionally need kms:Decrypt on this key.
resource "aws_kms_key" "rds_performance_insights" {
  description             = "CMK for RDS Performance/Database Insights data"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "${var.name_prefix}-rds-performance-insights-cmk"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_kms_alias" "rds_performance_insights" {
  name          = "alias/${var.name_prefix}/rds-performance-insights-cmk"
  target_key_id = aws_kms_key.rds_performance_insights.key_id
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
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
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
    Name        = "${var.name_prefix}-EBS-CMK"
    Environment = var.environment
    Terraform   = "true"
  }
}

### EBS KMS KEY ALIAS
resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.name_prefix}/ebs-cmk"
  target_key_id = aws_kms_key.ebs.id
}

## KMS KEY FOR LAMBDA
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
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
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
            "kms:ViaService"    = "lambda.${var.primary_region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.name_prefix}-lambda-cmk"
    Environment = var.environment
    Terraform   = "true"
  }
}

### ALIAS FOR LAMBDA KMS KEY
resource "aws_kms_alias" "lambda" {
  name          = "alias/${var.name_prefix}/lambda-cmk"
  target_key_id = aws_kms_key.lambda.id
}

## SECRETS MANAGER CMK
resource "aws_kms_key" "secrets_manager" {
  description             = "CMK for encrypting Secrets Manager secrets"
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
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # ALLOW SECRETS MANAGER SERVICE TO USE THIS KEY
      {
        Sid    = "AllowSecretsManager"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "${var.name_prefix}-Secrets-Manager-CMK"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_kms_alias" "secrets_manager" {
  name          = "alias/${var.name_prefix}/secrets-cmk"
  target_key_id = aws_kms_key.secrets_manager.arn
}

## BACKUP VAULT KMS KEY
resource "aws_kms_key" "backup_vault" {
  description             = "CMK for AWS Backup Vault"
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
          AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowBackupVault"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
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
    ] }
  )

  tags = {
    Name        = "${var.name_prefix}-Backup-CMK"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_kms_alias" "backup_vault" {
  name          = "alias/${var.name_prefix}/backup-cmk"
  target_key_id = aws_kms_key.backup_vault.arn
}

## ECR KMS KEY
resource "aws_kms_key" "ecr" {
  description             = "CMK for ECR"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.ecr_kms.json

  lifecycle {
    prevent_destroy = false # CHANGE THIS IN PROD
  }

  tags = {
    Name        = "${var.name_prefix}-ECR-CMK"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.name_prefix}/ecr-cmk"
  target_key_id = aws_kms_key.ecr.arn
}

### ECR KMS KEY POLICY DOCUMENT
data "aws_iam_policy_document" "ecr_kms" {
  statement {
    sid    = "EnableIAMPermissions"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"
      ]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }
}

# Foundation owns the admission gate and its key independently of application state.
resource "aws_kms_key" "job_admission_gate" {
  for_each = var.job_admission_applications

  description             = "Job admission gate CMK for ${var.name_prefix}-${each.key}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Enable account IAM delegation without depending on application role ARNs.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableIAMPermissions"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = {
    Name        = "${var.name_prefix}-${each.key}-job-admission-gate-cmk"
    Environment = var.environment
    Application = each.key
    Terraform   = "true"
  }
}

resource "aws_kms_alias" "job_admission_gate" {
  for_each = var.job_admission_applications

  name          = "alias/${var.name_prefix}/${each.key}/job-admission-gate"
  target_key_id = aws_kms_key.job_admission_gate[each.key].key_id
}
