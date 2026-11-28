mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws", dns_suffix = "amazonaws.com" } }
  mock_data "aws_region" { defaults = { region = "us-east-1" } }
}
variables {
  cloud_name              = "unit"
  environment             = "dev"
  bucket_admin_principals = ["arn:aws:iam::123456789012:role/bootstrap-admin"]
}
run "application_backends_default_absent" {
  command = plan
  assert {
    condition     = length(module.application_state) == 0 && output.tf_state_bucket_name == "unit-dev-state"
    error_message = "Existing foundation backend must keep its address/name and application backends must remain opt-in."
  }
}
run "application_backend_is_separate" {
  command = plan
  variables {
    application_state_backends = {
      demo = {
        bucket_name = "unit-dev-demo-123456789012-state"
        access = {
          plan_role_arn           = "arn:aws:iam::123456789012:role/application/demo-plan"
          apply_role_arn          = "arn:aws:iam::123456789012:role/application/demo-apply"
          administrator_role_arns = ["arn:aws:iam::123456789012:role/bootstrap-admin"]
        }
      }
    }
  }
  assert {
    condition = (
      length(module.application_state) == 1 &&
      output.tf_state_bucket_name == "unit-dev-state" &&
      output.application_state_backends["demo"].backend.bucket == "unit-dev-demo-123456789012-state" &&
      output.application_state_backends["demo"].backend.key == "application.tfstate" &&
      output.application_state_backends["demo"].backend.use_lockfile
    )
    error_message = "Application backend wiring must preserve the existing foundation backend and expose a separate application destination."
  }
}
