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
  abuseipdb_api_key  = "test-only-placeholder"

  bucket_admin_principals = [
    "arn:aws:iam::123456789012:role/test-admin"
  ]

  break_glass_trusted_principal_arns = [
    "arn:aws:iam::123456789012:role/test-admin"
  ]

  ecs_services = {
    api = {
      repository_name = "api"
      image_digest    = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      container_port  = 8080
      cpu             = 512
      memory          = 1024

      secrets_manager_secrets = {
        SHARED = "arn:aws:secretsmanager:us-east-1:123456789012:secret:shared-AbCdEf:password::"
      }

      ssm_parameters = {
        API_PARAMETER = "arn:aws:ssm:us-east-1:123456789012:parameter/shared/config"
      }

      task_execution_kms_key_arns = [
        "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      ]

      task_role_managed_policy_arns = [
        "arn:aws:iam::123456789012:policy/api-read"
      ]

      sidecars = {
        scanner = {
          repository_name = "scanner"
          image_digest    = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

          secrets_manager_secrets = {
            SHARED  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:shared-AbCdEf::AWSPREVIOUS:"
            SCANNER = "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl:::version123"
          }

          ssm_parameters = {
            SCANNER_PARAMETER = "arn:aws:ssm:us-east-1:123456789012:parameter/shared/config"
          }
        }
      }
    }

    worker = {
      repository_name = "worker"
      image_digest    = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      container_port  = 9090
      cpu             = 512
      memory          = 1024

      secrets_manager_secrets = {
        WORKER = "arn:aws:secretsmanager:us-east-1:123456789012:secret:worker-ZyXwVu"
      }
    }

    # Not yet deployable. Must not generate ECS IAM resources.
    pending = {
      repository_name = "pending"
      container_port  = 8081
      cpu             = 512
      memory          = 1024
    }
  }
}

run "baseline_ecs_iam_derivation" {
  command = plan

  # Narrow the first test to the IAM dependency graph.
  plan_options {
    target = [module.iam]
  }

  assert {
    condition = (
      toset(keys(local.ecs_iam_services)) == toset(["api", "worker"])
    )

    error_message = "Only deployable ECS services must enter the IAM contract."
  }

  assert {
    condition = (
      local.ecs_iam_services["api"].ecr_repository_arns == toset([
        "arn:aws:ecr:us-east-1:123456789012:repository/unit-test-dev-api",
        "arn:aws:ecr:us-east-1:123456789012:repository/unit-test-dev-scanner"
      ]) &&
      local.ecs_iam_services["worker"].ecr_repository_arns == toset([
        "arn:aws:ecr:us-east-1:123456789012:repository/unit-test-dev-worker"
      ])
    )

    error_message = "Each ECS service must receive its exact primary and sidecar ECR repository inventory."
  }

  assert {
    condition = (
      local.ecs_iam_services["api"].execution_secret_arns == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:shared-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl"
      ]) &&
      local.ecs_iam_services["worker"].execution_secret_arns == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:worker-ZyXwVu"
      ])
    )

    error_message = "Secret selectors must be normalized and shared secret ARNs deduplicated without cross-service leakage."
  }

  assert {
    condition = (
      local.ecs_iam_services["api"].execution_ssm_parameter_arns == toset([
        "arn:aws:ssm:us-east-1:123456789012:parameter/shared/config"
      ]) &&
      length(local.ecs_iam_services["worker"].execution_ssm_parameter_arns) == 0
    )

    error_message = "SSM references must be deduplicated and isolated to their owning ECS service."
  }

  assert {
    condition = (
      local.ecs_iam_services["api"].task_execution_kms_key_arns == toset([
        "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      ]) &&
      local.ecs_iam_services["api"].task_role_managed_policy_arns == toset([
        "arn:aws:iam::123456789012:policy/api-read"
      ]) &&
      length(local.ecs_iam_services["worker"].task_execution_kms_key_arns) == 0 &&
      length(local.ecs_iam_services["worker"].task_role_managed_policy_arns) == 0
    )

    error_message = "KMS and application task-role policy inventories must remain service-specific."
  }
}

run "empty_services_have_empty_iam_contract" {
  command = plan

  variables {
    ecs_services = {}
  }

  plan_options {
    target = [module.iam]
  }

  assert {
    condition = (
      length(local.ecs_iam_services) == 0 &&
      length(local.deployable_ecs_services) == 0
    )

    error_message = "An empty ECS configuration must produce an empty IAM contract."
  }
}