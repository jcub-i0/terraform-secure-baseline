resource "aws_dynamodb_table" "execution_ledger" {
  count = length(var.jobs) > 0 ? 1 : 0

  name         = "${var.name_prefix}- job-execution-ledger"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Keep admission state recoverable
  point_in_time_recovery {
    enabled = true
  }

  # Protect the ledger from accidental table deletion
  deletion_protection_enabled = true

  # No TTL: expiration must never release an unresolved job slot
  tags = {
    Name        = "${var.name_prefix}-job-execution-ledger"
    Environment = var.environment
    Terraform   = "true"
  }
}