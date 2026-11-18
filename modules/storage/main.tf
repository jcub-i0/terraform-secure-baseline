data "aws_partition" "current" {}

# S3 RESOURCES
## CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket" "centralized_logs" {
  bucket              = "${var.name_prefix}-centralized-logs-${var.random_id}"
  object_lock_enabled = false # Object Lock requires a separately qualified WORM design
  force_destroy       = var.centralized_logs_force_destroy

  # Terraform lifecycle meta-arguments cannot depend on variable inputs.
  # force_destroy is therefore profile-controlled; this is not WORM protection.
  lifecycle {
    prevent_destroy = false
  }

  tags = {
    Name        = "${var.name_prefix}-Centralized-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

## BLOCK PUBLIC ACCESS TO THE CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket_public_access_block" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

## ENABLE SSE FOR THE CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket_server_side_encryption_configuration" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.logs_cmk_arn
    }
    bucket_key_enabled = true
  }
}

## ENABLE VERSIONING FOR THE CENTRALIZED LOGS S3 BUCKET
resource "aws_s3_bucket_versioning" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

## ENSURE BUCKET OWNER ALWAYS OWNS ALL OBJECTS, REGARDLESS OF UPLOADER.
## THIS DISABLES ACLs AND AVOIDS CROSS-ACCOUNT WRITE PERMISSION ISSUES.
resource "aws_s3_bucket_ownership_controls" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

## LIFECYCLE RETENTION FOR CENTRALIZED LOGS BUCKET (COST REDUCTION)
resource "aws_s3_bucket_lifecycle_configuration" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id

  rule {
    id     = "centralized-logs-retention"
    status = "Enabled"

    filter {} # ENTIRE BUCKET -- CAN BE SCOPED

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 2555 # 7 YEARS
    }

    noncurrent_version_expiration {
      noncurrent_days = 2555
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

## S3 BUCKET POLICIES
### CENTRALIZED LOGS S3 BUCKET POLICY
data "aws_iam_policy_document" "centralized_logs" {
  # Deny direct deletion of objects and versions while this removable policy is attached.
  # This is not S3 Object Lock, WORM, or protection against approved teardown.
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

    resources = ["${aws_s3_bucket.centralized_logs.arn}/*"]
  }

  # DENY CHANGING BUCKET POLICY UNLESS BUCKET ADMIN PRINCIPAL
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

    resources = [aws_s3_bucket.centralized_logs.arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.bucket_admin_principals
    }
  }

  # DENY DISABLING VERSIONING UNLESS BUCKET ADMIN PRINCIPAL
  statement {
    sid     = "DenyVersioningChanges"
    effect  = "Deny"
    actions = ["s3:PutBucketVersioning"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [aws_s3_bucket.centralized_logs.arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.bucket_admin_principals
    }
  }

  # ENFORCE ENCRYPTION ON ALL PUTS
  statement {
    sid     = "DenyUnencryptedObjectUploads"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.centralized_logs.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # DENY ANYTHING LACKING ENCRYPTION
  statement {
    sid     = "DenyMissingEncryptionHeader"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.centralized_logs.arn}/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["true"]
    }
  }

  # CONFIG - ALLOW CONFIG TO CHECK ACL
  statement {
    sid     = "AWSConfigAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    resources = [aws_s3_bucket.centralized_logs.arn]
  }

  # CONFIG - ALLOW CONFIG TO WRITE OBJECTS
  statement {
    sid     = "AWSConfigWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.centralized_logs.arn}/Config/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # CONFIG - ALLOW CONFIG TO CHECK FOR BUCKET
  statement {
    sid     = "AWSConfigBucketExistenceCheck"
    effect  = "Allow"
    actions = ["s3:ListBucket"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    resources = [aws_s3_bucket.centralized_logs.arn]
  }

  # CLOUDTRAIL - ALLOW CLOUDTRAIL TO VERIFY BUCKET ACL
  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = [aws_s3_bucket.centralized_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  # CLOUDTRAIL - ALLOW CLOUDTRAIL TO WRITE LOGS
  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.centralized_logs.arn}/CloudTrail/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # NETWORK FIREWALL LOG DELIVERY - ACL CHECK
  # Keep AWS's canonical log-delivery SID so the service recognizes this
  # statement and does not append a duplicate bucket-policy statement.
  statement {
    sid     = "AWSLogDeliveryAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    resources = [aws_s3_bucket.centralized_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:logs:${var.primary_region}:${var.account_id}:*"
      ]
    }
  }

  # NETWORK FIREWALL LOG DELIVERY - WRITE
  # Keep AWS's canonical log-delivery SID so the service recognizes this
  # statement and does not append a duplicate bucket-policy statement.
  statement {
    sid     = "AWSLogDeliveryWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    resources = [
      "${aws_s3_bucket.centralized_logs.arn}/${var.cloud_name}/firewall/flow/AWSLogs/${var.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:logs:${var.primary_region}:${var.account_id}:*"
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "centralized_logs" {
  bucket = aws_s3_bucket.centralized_logs.id
  policy = data.aws_iam_policy_document.centralized_logs.json
}
