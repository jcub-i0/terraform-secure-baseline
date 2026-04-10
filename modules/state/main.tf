###############
# STATE MODULE
###############

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

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

## BLOCK PUBLIC ACCESS TO THE STATE BUCKET
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}