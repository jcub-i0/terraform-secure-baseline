###############
# STATE MODULE
###############

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

# KMS KEY FOR STATE S3 BUCKET
resource "aws_kms_key" "state" {
  description             = "CMK for the the State S3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
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
