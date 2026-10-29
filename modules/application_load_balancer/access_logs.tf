# Dedicated S3 destination for Application Load Balancer access logs
# Only created when the owning ALB module is instantiated and logging is enabled

locals {
  access_logs_bucket_name = "${var.name_prefix}-alb-access-logs-${var.random_id}"
}

data "aws_partition" "current" {}
data "aws_region" "current" {}

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

# Expire current logs after the configured period
# Remove noncurrent object versions after one day
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

data "aws_iam_policy_document" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  # Grant only the expected ALB permission to deliver logs
  statement {
    sid    = "AllowALBLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.access_logs[0].arn}/alb/AWSLogs/${var.account_id}/*"
    ]

    # Construct the ARN from the deterministic ALB name
    # to avoid introducing an ALB/bucket-policy dependency cycle
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:elasticloadbalancing:${data.aws_region.current.region}:${var.account_id}:loadbalancer/*"
      ]
    }
  }

  # Deny direct deletion of log objects and versions
  # S3 Lifecycle expiration remains available
  statement {
    sid    = "DenyDeleteLogs"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion"
    ]

    resources = [
      "${aws_s3_bucket.access_logs[0].arn}/*"
    ]
  }

  # Protect the bucket policy while permitting approved administrators
  statement {
    sid    = "DenyBucketPolicyChanges"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy"
    ]

    resources = [aws_s3_bucket.access_logs[0].arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.bucket_admin_principals
    }
  }

  statement {
    sid    = "DenyProtectedBucketConfigurationChanges"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketOwnershipControls",
    ]

    resources = [aws_s3_bucket.access_logs[0].arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.bucket_admin_principals
    }
  }

  # Protect bucket versioning from unauthorized changes
  statement {
    sid    = "DenyVersioningChanges"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:PutBucketVersioning"]

    resources = [aws_s3_bucket.access_logs[0].arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.bucket_admin_principals
    }
  }

  # Require HTTPS for bucket and object operations
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.access_logs[0].arn,
      "${aws_s3_bucket.access_logs[0].arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  count = var.access_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  policy = data.aws_iam_policy_document.access_logs[0].json
}