resource "aws_dynamodb_table" "admission_gate" {
  name         = "${var.name_prefix}-job-admission-gate"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.admission_gate_cmk_arn
  }

  deletion_protection_enabled = true

  # No TTL or Terraform-managed items: the protected controller owns gate state.
  tags = {
    Name        = "${var.name_prefix}-job-admission-gate"
    Environment = var.environment
    Terraform   = "true"
  }
}