mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = [
        "us-east-1a",
        "us-east-1b",
        "us-east-1c"
      ]
    }
  }

  mock_ephemeral "aws_secretsmanager_random_password" {
    defaults = {
      random_password = "TestOnlyMockPassword123!"
    }
  }

  # Test-only policy JSON for unrelated baseline resources.
  # Actual ECS IAM policy generation is tested separately in modules/ecs_workload_iam.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"AWS\":\"arn:aws:iam::123456789012:root\"},\"Resource\":\"*\"}]}"
    }
  }
}

# Supply deterministic ECR outputs without testing ECR itself.
override_module {
  target = module.ecr

  outputs = {
    repositories = {
      for name in ["api", "scanner", "worker"] :
      name => {
        arn            = "arn:aws:ecr:us-east-1:123456789012:repository/unit-test-dev-${name}"
        repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/unit-test-dev-${name}"
      }
    }
  }
}

variables {
  cloud_name         = "unit-test"
  environment        = "dev"
  deployment_profile = "minimal"
  primary_region     = "us-east-1"
  account_id         = "123456789012"
  random_id          = "1234abcd"
  abuseipdb_api_key  = "dummy"

  bucket_admin_principals            = ["arn:aws:iam::123456789012:role/test-admin"]
  break_glass_trusted_principal_arns = ["arn:aws:iam::123456789012:role/test-admin"]
}

run "default_has_no_admission_infrastructure" {
  command = plan

  assert {
    condition = (
      length(aws_kms_key.job_admission_gate) == 0 &&
      length(aws_kms_alias.job_admission_gate) == 0 &&
      length(module.job_admission_gate) == 0 &&
      length(output.job_admission_gates) == 0
    )
    error_message = "Existing foundations must create no admission resources unless applications are explicitly inventoried."
  }
}

run "separate_application_gates_and_keys" {
  command = plan

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

  override_resource {
    override_during = plan
    target          = module.job_admission_gate["billing"].aws_dynamodb_table.admission_gate
    values = {
      arn = "arn:aws:dynamodb:us-east-1:123456789012:table/unit-test-dev-billing-job-admission-gate"
    }
  }

  override_resource {
    override_during = plan
    target          = module.job_admission_gate["reports"].aws_dynamodb_table.admission_gate
    values = {
      arn = "arn:aws:dynamodb:us-east-1:123456789012:table/unit-test-dev-reports-job-admission-gate"
    }
  }

  assert {
    condition = (
      toset(keys(aws_kms_key.job_admission_gate)) == var.job_admission_applications &&
      toset(keys(aws_kms_alias.job_admission_gate)) == var.job_admission_applications &&
      toset(keys(module.job_admission_gate)) == var.job_admission_applications &&
      output.job_admission_gates == {
        billing = {
          table_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/unit-test-dev-billing-job-admission-gate"
          cmk_arn   = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
        }
        reports = {
          table_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/unit-test-dev-reports-job-admission-gate"
          cmk_arn   = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
        }
      }
    )
    error_message = "Each inventoried application must receive its own gate/key pair without cross-application key bindings."
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
