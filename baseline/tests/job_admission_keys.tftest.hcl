# Run the security module directly using the baseline test harness and lockfile.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  # Unrelated existing policies are outside this focused key test.
  # The admission key policy uses jsonencode and is asserted below.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"AWS\":\"arn:aws:iam::123456789012:root\"},\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  cloud_name                      = "unit-test"
  name_prefix                     = "unit-test-dev"
  environment                     = "dev"
  primary_region                  = "us-east-1"
  account_id                      = "123456789012"
  centralized_logs_bucket_name    = "unit-test-dev-centralized-logs"
  compliance_topic_arn            = "arn:aws:sns:us-east-1:123456789012:compliance"
  secops_topic_arn                = "arn:aws:sns:us-east-1:123456789012:secops"
  secops_event_bus_name           = "unit-test-dev-secops"
  sec_notifs_eventbridge_dlq_arn  = "arn:aws:sqs:us-east-1:123456789012:secops-dlq"
  guardduty_features              = []
  enable_config                   = false
  inspector_enabled               = false
  manage_securityhub_cspm_locally = false
  manage_securityhub_v2_locally   = false
  manage_guardduty_locally        = false
}

run "default_has_no_admission_keys" {
  command = plan

  module {
    source = "../modules/security"
  }

  assert {
    condition = (
      length(aws_kms_key.job_admission_gate) == 0 &&
      length(aws_kms_alias.job_admission_gate) == 0 &&
      length(output.job_admission_gate_cmk_arns) == 0
    )
    error_message = "An empty application inventory must create no admission keys or aliases."
  }
}

run "admission_key_security_contract" {
  command = plan

  module {
    source = "../modules/security"
  }

  variables {
    job_admission_applications = ["billing", "reports"]
  }

  override_resource {
    override_during = plan
    target          = aws_kms_key.job_admission_gate["billing"]
    values = {
      key_id = "11111111-1111-1111-1111-111111111111"
      arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
    }
  }

  override_resource {
    override_during = plan
    target          = aws_kms_key.job_admission_gate["reports"]
    values = {
      key_id = "22222222-2222-2222-2222-222222222222"
      arn    = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
    }
  }

  assert {
    condition = (
      toset(keys(aws_kms_key.job_admission_gate)) == var.job_admission_applications &&
      toset(keys(aws_kms_alias.job_admission_gate)) == var.job_admission_applications
    )
    error_message = "Each inventoried application must have its own admission key and alias."
  }

  assert {
    condition = alltrue([
      for application, key in aws_kms_key.job_admission_gate :
      key.enable_key_rotation &&
      key.deletion_window_in_days == 30 &&
      jsondecode(key.policy).Statement == [{
        Sid       = "EnableIAMPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::123456789012:root" }
        Action    = "kms:*"
        Resource  = "*"
      }] &&
      aws_kms_alias.job_admission_gate[application].target_key_id == key.key_id &&
      aws_kms_alias.job_admission_gate[application].name == "alias/unit-test-dev/${application}/job-admission-gate"
    ])
    error_message = "Gate keys must retain rotation, the deletion window, account IAM delegation, and per-application aliases."
  }
}
