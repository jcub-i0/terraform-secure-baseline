# Dedicated S3 destination for Application Load Balancer access logs
# Only created when the owning ALB module is instantiated and logging is enabled

locals {
  access_logs_bucket_name = "${var.name_prefix}-alb-access-logs-${var.random_id}"
}

resource "aws_s3_bucket" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket        = local.access_logs_bucket_name
  force_destroy = var.access_logs_force_destroy

  tags = {
    Name        = "${var.name_prefix}-ALB-Access-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

# Prevent public access
resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Direct ALB-to-S3 access logging requires SSE-S3
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Preserve object version history until lifecycle expiration
resource "aws_s3_bucket_versioning" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Disable object ACLs and enforce bucket ownership
resource "aws_s3_bucket_ownership_controls" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Expire current logs after the configured period.
# Remove noncurrent object versions after one day.
resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "alb-access-logs-retention"
    status = "Enabled"

    filter {
      prefix = "alb/"
    }

    expiration {
      days = var.access_logs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}