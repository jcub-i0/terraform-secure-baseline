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
  # Actual IAM policy generation is tested separately in modules/iam.
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
# M1-N5C-A: reject unsafe inputs at the actual IAM interface before policy generation.

run "n5ca_reject_primary_ssm_star" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "*" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_question" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "?" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_arn_star" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/*" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_arn_question" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/config?" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_region_wildcard" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:aws:ssm:*:123456789012:parameter/app/config" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_account_wildcard" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:12345678901?:parameter/app/config" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_bare_path" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "/app/config" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_unsupported_partition" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:other:ssm:us-east-1:123456789012:parameter/app/config" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_wrong_resource" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:document/app" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_primary_ssm_empty_parameter" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/" }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_star" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "*" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_question" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "?" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_arn_star" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/*" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_arn_question" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/config?" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_region_wildcard" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:aws:ssm:*:123456789012:parameter/app/config" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_account_wildcard" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:12345678901?:parameter/app/config" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_bare_path" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "/app/config" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_unsupported_partition" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:other:ssm:us-east-1:123456789012:parameter/app/config" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_wrong_resource" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:document/app" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_sidecar_ssm_empty_parameter" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { scanner = merge(var.ecs_services.api.sidecars.scanner, { ssm_parameters = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/" } }) }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_star" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["*"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_question" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["?"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_key_star" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/*"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_key_question" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/mrk-0123456789abcdef0123456789abcde?"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_region_wildcard" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:*:123456789012:key/mrk-0123456789abcdef0123456789abcdef"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_account_wildcard" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:12345678901?:key/mrk-0123456789abcdef0123456789abcdef"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_bare_id" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["22222222-2222-2222-2222-222222222222"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_alias_arn" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:alias/app"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_unsupported_partition" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:other:kms:us-east-1:123456789012:key/mrk-0123456789abcdef0123456789abcdef"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_empty_key" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_kms_whitespace" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/ key"]
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_10_sidecars" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { for i in range(10) : "helper_${i}" => var.ecs_services.api.sidecars.scanner }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_11_sidecars" {
  command = plan

  plan_options { target = [module.iam] }

  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        sidecars = { for i in range(11) : "helper_${i}" => var.ecs_services.api.sidecars.scanner }
      })
    }
  }

  expect_failures = [var.ecs_services]
}

run "n5ca_reject_pending_service_with_ten_sidecars" {
  command = plan
  plan_options { target = [module.iam] }
  variables {
    ecs_services = {
      api = merge(var.ecs_services.api, {
        image_digest = null
        sidecars     = { for i in range(10) : "helper_${i}" => var.ecs_services.api.sidecars.scanner }
      })
    }
  }
  expect_failures = [var.ecs_services]
}

run "n5ca_accept_0_sidecars_per_service" {
  command = plan
  plan_options { target = [module.iam] }
  variables {
    ecs_services = {
      for name in ["api", "worker"] : name => merge(var.ecs_services.api, {
        sidecars = { for i in range(0) : "helper_${i}" => var.ecs_services.api.sidecars.scanner }
      })
    }
  }
  assert {
    condition = length(local.ecs_iam_services) == 2 && alltrue([
      for service in values(var.ecs_services) : length(service.sidecars) == 0
    ])
    error_message = "The declared container limit must apply independently to each service."
  }
}

run "n5ca_accept_9_sidecars_per_service" {
  command = plan
  plan_options { target = [module.iam] }
  variables {
    ecs_services = {
      for name in ["api", "worker"] : name => merge(var.ecs_services.api, {
        sidecars = { for i in range(9) : "helper_${i}" => var.ecs_services.api.sidecars.scanner }
      })
    }
  }
  assert {
    condition = length(local.ecs_iam_services) == 2 && alltrue([
      for service in values(var.ecs_services) : length(service.sidecars) == 9
    ])
    error_message = "The declared container limit must apply independently to each service."
  }
}

run "n5ca_accept_exact_ssm_and_kms_partition_arns" {
  command = plan
  plan_options { target = [module.iam] }
  variables {
    ecs_services = {
      for partition, region in { aws = "us-east-1", aws-us-gov = "us-gov-west-1", aws-cn = "cn-north-1" } :
      partition => merge(var.ecs_services.api, {
        ssm_parameters = { CONFIG = "arn:${partition}:ssm:${region}:123456789012:parameter/app/Config_1.2-test" }
        task_execution_kms_key_arns = [
          "arn:${partition}:kms:${region}:123456789012:key/22222222-2222-2222-2222-222222222222",
          "arn:${partition}:kms:${region}:123456789012:key/mrk-0123456789abcdef0123456789abcdef"
        ]
        sidecars = {
          scanner = merge(var.ecs_services.api.sidecars.scanner, {
            ssm_parameters = { CONFIG = "arn:${partition}:ssm:${region}:123456789012:parameter/app/Config_1.2-test" }
          })
        }
      })
    }
  }
  assert {
    condition = alltrue([
      for service_name, service in var.ecs_services :
      local.ecs_iam_services[service_name].execution_ssm_parameter_arns == toset(values(service.ssm_parameters)) &&
      local.ecs_iam_services[service_name].task_execution_kms_key_arns == service.task_execution_kms_key_arns
    ])
    error_message = "All three AWS partitions must retain exact SSM and KMS key scopes, including multi-Region keys."
  }
}
