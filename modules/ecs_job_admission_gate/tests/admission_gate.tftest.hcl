provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name_prefix            = "example-app-test"
  environment            = "test"
  admission_gate_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
}

run "protected_gate_storage" {
  command = plan

  assert {
    condition = (
      aws_dynamodb_table.admission_gate.name == "example-app-test-job-admission-gate" &&
      aws_dynamodb_table.admission_gate.billing_mode == "PAY_PER_REQUEST" &&
      aws_dynamodb_table.admission_gate.hash_key == "pk" &&
      aws_dynamodb_table.admission_gate.deletion_protection_enabled &&
      output.admission_gate.cmk_arn == var.admission_gate_cmk_arn
    )
    error_message = "The gate must retain its storage contract, protected key binding, and deletion protection."
  }
}

run "reject_missing_cmk" {
  command = plan
  variables {
    admission_gate_cmk_arn = null
  }
  expect_failures = [var.admission_gate_cmk_arn]
}

run "reject_alias_instead_of_key" {
  command = plan
  variables {
    admission_gate_cmk_arn = "arn:aws:kms:us-east-1:123456789012:alias/gate"
  }
  expect_failures = [var.admission_gate_cmk_arn]
}
