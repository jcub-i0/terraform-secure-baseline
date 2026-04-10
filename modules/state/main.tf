###############
# STATE MODULE
###############

# KMS KEY FOR STATE S3 BUCKET
resource "aws_kms_key" "state" {
  description             = "CMK for the the State S3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW FULL ACCESS FOR ROOT ACCOUNT
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # ALLOW S3
      {
        Sid    = "AllowS3UseOfKeyForThisAccount"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = var.account_id
            "kms:ViaService"    = "s3.${var.primary_region}.amazonaws.com"
          }
        }
      },
    ]
  })

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.cloud_name}-state"
    Environment = var.environment
    Terraform = "true"
  }
}

## ALIAS FOR STATE CMK / KMS KEY
resource "aws_kms_alias" "state" {
  name          = "alias/${var.cloud_name}-state"
  target_key_id = aws_kms_key.state.key_id
}

# CREATE STATE S3 BUCKET
resource "aws_s3_bucket" "state" {
  bucket              = "${var.cloud_name}-state"
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.cloud_name}-state"
    Environment = var.environment
    Terraform   = "true"
  }
}

# BLOCK PUBLIC ACCESS TO THE STATE BUCKET
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ENABLE SSE FOR THE STATE S3 BUCKET
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

# ENABLE VERSIONING FOR THE STATE S3 BUCKET
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

## ENSURE BUCKET OWNER ALWAYS OWNS ALL OBJECTS, REGARDLESS OF UPLOADER.
## THIS DISABLES ACLs AND AVOIDS CROSS-ACCOUNT WRITE PERMISSION ISSUES.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# STATE S3 BUCKET POLICY
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # DENY CHANGING BUCKET POLICY UNLESS BUCKET ADMIN PRINCIPAL
      {
        Sid       = "DenyBucketPolicyChanges"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy"
        ]
        Resource = aws_s3_bucket.state.arn
        Condition = {
          "ForAnyValue:ArnNotEquals" = {
            "aws:PrincipalArn" : var.bucket_admin_principals
          }
        }
      },
      #DENY DISABLING VERSIONING UNLESS BUCKET ADMIN PRINCIPAL
      {
        Sid       = "DenyVersioningChanges"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:PutBucketVersioning"
        ]
        Resource = aws_s3_bucket.state.arn
        Condition = {
          "ForAnyValue:ArnNotEquals" = {
            "aws:PrincipalArn" : var.bucket_admin_principals
          }
        }
      },
      # DENY CHANGES TO THE BUCKET ENCRYPTION CONFIG UNLESS ADMIN PRINCIPAL
      {
        Sid = "DenyEncryptionConfigChanges"
        Effect = "Deny"
        Principal = "*"
        Action = [
            "s3:PutEncryptionConfiguration"
        ]
        Resource = aws_s3_bucket.state.arn
        Condition = {
            "ForAnyValue:ArnNotEquals" = {
                "aws:PrincipalArn" : var.bucket_admin_principals
            }
        }
      }
    ]
  })
}

# STATE DYNAMODB LOCK TABLE
resource "aws_dynamodb_table" "state_lock" {
  name         = "${var.cloud_name}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.cloud_name}-Terraform-Lock"
    Environment = var.environment
    Terraform   = "true"
  }
}