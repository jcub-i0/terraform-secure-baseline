data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  bucket_arn       = "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}"
  account_arn      = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  state_key        = "application.tfstate"
  state_object_arn = "${local.bucket_arn}/${local.state_key}"
  lock_object_arn  = "${local.state_object_arn}.tflock"

  backend_roles = sort([var.access.plan_role_arn, var.access.apply_role_arn])
  admin_roles   = sort(tolist(var.access.administrator_role_arns))
  all_roles     = sort(tolist(setunion(toset(local.backend_roles), var.access.administrator_role_arns)))

  tags = {
    Name        = var.name_prefix
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform backend for ${var.name_prefix}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = jsonencode(local.key_policy)
  tags                    = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.name_prefix}/application-state"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket        = var.bucket_name
  force_destroy = false
  tags          = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode(local.bucket_policy)
}
