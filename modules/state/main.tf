###############
# STATE MODULE
###############

# KMS KEY FOR STATE S3 BUCKET
resource "aws_kms_key" "state" {
  description             = "CMK for the the State S3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }

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
    ]
  })
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
    Name        = "${var.cloud_name}-State"
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