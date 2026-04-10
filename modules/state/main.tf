###############
# STATE MODULE
###############

locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

resource "aws_s3_bucket" "state_bucket" {
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