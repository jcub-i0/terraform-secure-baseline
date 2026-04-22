locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "account_id" {}