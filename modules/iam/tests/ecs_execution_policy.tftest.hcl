provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

# Offline substitutes for AWS-managed policies used by Lambda roles.
# These are unrelated to the ECS IAM policies under test.

override_data {
  target = data.aws_iam_policy.lambda_vpc

  values = {
    arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  }
}

override_data {
  target = data.aws_iam_policy.lambda_logs

  values = {
    arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  }
}

override_data {
  target = data.aws_iam_policy.lambda_xray

  values = {
    arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
  }
}

variables {
  cloud_name     = "unit-test"
  name_prefix    = "unit-test-dev"
  environment    = "dev"
  account_id     = "123456789012"
  primary_region = "us-east-1"

  cloudtrail_log_group_arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/cloudtrail/test"
  secops_topic_arn         = "arn:aws:sns:us-east-1:123456789012:secops"

  logs_cmk_arn            = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  secrets_manager_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"

  centralized_logs_bucket_arn           = "arn:aws:s3:::unit-test-logs"
  flowlogs_firehose_delivery_stream_arn = "arn:aws:firehose:us-east-1:123456789012:deliverystream/test"
  flowlogs_log_group_arn                = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc/flowlogs"

  secops_event_bus_arn               = "arn:aws:events:us-east-1:123456789012:event-bus/secops"
  threat_intel_api_keys_arn          = "arn:aws:secretsmanager:us-east-1:123456789012:secret:api-AbCdEf"
  lambda_ip_enrichment_log_group_arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/enrichment"

  break_glass_trusted_principal_arns = [
    "arn:aws:iam::123456789012:role/test-admin"
  ]

  lambda_ec2_isolation_dlq_arn = "arn:aws:sqs:us-east-1:123456789012:isolation-dlq"
  lambda_ec2_rollback_dlq_arn  = "arn:aws:sqs:us-east-1:123456789012:rollback-dlq"
  lambda_ip_enrichment_dlq_arn = "arn:aws:sqs:us-east-1:123456789012:enrichment-dlq"

  ecs_iam_services = {
    api = {
      ecr_repository_arns = [
        "arn:aws:ecr:us-east-1:123456789012:repository/api",
        "arn:aws:ecr:us-east-1:123456789012:repository/scanner"
      ]

      log_group_arns = [
        "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/unit-test-dev/api"
      ]

      execution_secret_arns = [
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl"
      ]

      execution_ssm_parameter_arns = [
        "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
      ]

      task_execution_kms_key_arns = [
        "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      ]
    }
  }
}

run "generates_scoped_execution_policy" {
  command = plan

  assert {
    condition = (
      length(aws_iam_role.ecs_task_execution_roles) == 1 &&
      length(aws_iam_role.ecs_task_roles) == 1 &&
      length(aws_iam_role_policy.ecs_task_execution_policies) == 1
    )

    error_message = "One ECS service must generate exactly one execution role, task role, and execution policy."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowECRImagePulls" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:ecr:us-east-1:123456789012:repository/api",
        "arn:aws:ecr:us-east-1:123456789012:repository/scanner"
      ])
    ]) == 1

    error_message = "ECR image-pull permissions must cover exactly the declared primary and sidecar repositories."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowSecretsManagerRead" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl"
      ])
    ]) == 1

    error_message = "Secrets Manager permissions must cover exactly the declared underlying secret ARNs."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowSSMParameterRead" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
      ])
    ]) == 1

    error_message = "SSM permissions must be restricted to declared parameter ARNs."
  }

  assert {
    condition = length([
      for statement in jsondecode(
        aws_iam_role_policy.ecs_task_execution_policies["api"].policy
      ).Statement : statement
      if statement.Sid == "AllowExecutionKMSDecrypt" &&
      toset(flatten([statement.Resource])) == toset([
        "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      ])
    ]) == 1

    error_message = "KMS decrypt permissions must be restricted to declared execution keys."
  }
}

run "empty_services_generate_no_ecs_iam" {
  command = plan

  variables {
    ecs_iam_services = {}
  }

  assert {
    condition = (
      length(aws_iam_role.ecs_task_execution_roles) == 0 &&
      length(aws_iam_role.ecs_task_roles) == 0 &&
      length(aws_iam_role_policy.ecs_task_execution_policies) == 0 &&
      length(aws_iam_role_policy_attachment.ecs_task_managed_policies) == 0
    )

    error_message = "An empty ECS service map must generate no ECS IAM roles, execution policies, or task-role policy attachments."
  }
}

run "multi_service_iam_isolation" {
  command = plan

  variables {
    ecs_iam_services = {
      api = {
        ecr_repository_arns = [
          "arn:aws:ecr:us-east-1:123456789012:repository/api",
          "arn:aws:ecr:us-east-1:123456789012:repository/scanner"
        ]

        log_group_arns = [
          "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/unit-test-dev/api"
        ]

        execution_secret_arns = [
          "arn:aws:secretsmanager:us-east-1:123456789012:secret:api-AbCdEf"
        ]

        execution_ssm_parameter_arns = [
          "arn:aws:ssm:us-east-1:123456789012:parameter/api/config"
        ]

        task_execution_kms_key_arns = [
          "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
        ]

        task_role_managed_policy_arns = [
          "arn:aws:iam::123456789012:policy/api-read"
        ]
      }

      worker = {
        ecr_repository_arns = [
          "arn:aws:ecr:us-east-1:123456789012:repository/worker"
        ]

        log_group_arns = [
          "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/unit-test-dev/worker"
        ]

        execution_secret_arns = [
          "arn:aws:secretsmanager:us-east-1:123456789012:secret:worker-GhIjKl"
        ]
      }
    }
  }

  # Exactly two independent ECS IAM resource sets.
  assert {
    condition = (
      toset(keys(aws_iam_role.ecs_task_execution_roles)) == toset(["api", "worker"]) &&
      toset(keys(aws_iam_role.ecs_task_roles)) == toset(["api", "worker"]) &&
      toset(keys(aws_iam_role_policy.ecs_task_execution_policies)) == toset(["api", "worker"])
    )

    error_message = "Each ECS service must have its own execution role, task role, and execution policy."
  }

  # Each service can pull only from its own declared repositories.
  assert {
    condition = alltrue([
      for service_name, service in var.ecs_iam_services :
      length([
        for statement in jsondecode(
          aws_iam_role_policy.ecs_task_execution_policies[service_name].policy
        ).Statement : statement
        if statement.Sid == "AllowECRImagePulls" &&
        toset(flatten([statement.Resource])) == service.ecr_repository_arns
      ]) == 1
    ])

    error_message = "ECR pull permissions must remain isolated to each service's declared repository inventory."
  }

  # CloudWatch log-write permissions must also remain isolated.
  assert {
    condition = alltrue([
      for service_name, service in var.ecs_iam_services :
      length([
        for statement in jsondecode(
          aws_iam_role_policy.ecs_task_execution_policies[service_name].policy
        ).Statement : statement
        if statement.Sid == "AllowCloudWatchLogWrites" &&
        toset(flatten([statement.Resource])) == toset([
          for arn in service.log_group_arns : "${arn}:*"
        ])
      ]) == 1
    ])

    error_message = "CloudWatch log-write permissions must match each service's own log groups."
  }

  # No service should inherit another service's Secrets Manager permissions.
  assert {
    condition = alltrue([
      for service_name, service in var.ecs_iam_services :
      length([
        for statement in jsondecode(
          aws_iam_role_policy.ecs_task_execution_policies[service_name].policy
        ).Statement : statement
        if statement.Sid == "AllowSecretsManagerRead" &&
        toset(flatten([statement.Resource])) == service.execution_secret_arns
      ]) == 1
    ])

    error_message = "Secrets Manager read permissions must remain isolated between ECS services."
  }

  # Verify exact optional-statement inventory and API-only SSM/KMS scopes.
  assert {
    condition = (
      alltrue([
        for service_name, service in var.ecs_iam_services :
        toset([
          for statement in jsondecode(
            aws_iam_role_policy.ecs_task_execution_policies[service_name].policy
          ).Statement : statement.Sid
          ]) == toset(concat(
          [
            "AllowECRAuthorization",
            "AllowECRImagePulls",
            "AllowCloudWatchLogWrites"
          ],
          length(service.execution_secret_arns) > 0 ? ["AllowSecretsManagerRead"] : [],
          length(service.execution_ssm_parameter_arns) > 0 ? ["AllowSSMParameterRead"] : [],
          length(service.task_execution_kms_key_arns) > 0 ? ["AllowExecutionKMSDecrypt"] : [],
          length(service.guardduty_agent_ecr_repository_arns) > 0 ? ["AllowGuardDutyAgentImagePulls"] : []
        ))
      ]) &&
      length([
        for statement in jsondecode(
          aws_iam_role_policy.ecs_task_execution_policies["api"].policy
        ).Statement : statement
        if statement.Sid == "AllowSSMParameterRead" &&
        toset(flatten([statement.Resource])) == toset([
          "arn:aws:ssm:us-east-1:123456789012:parameter/api/config"
        ])
      ]) == 1 &&
      length([
        for statement in jsondecode(
          aws_iam_role_policy.ecs_task_execution_policies["api"].policy
        ).Statement : statement
        if statement.Sid == "AllowExecutionKMSDecrypt" &&
        toset(flatten([statement.Resource])) == toset([
          "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
        ])
      ]) == 1
    )

    error_message = "Optional IAM statements must be present only when declared and must retain exact resource scopes."
  }

  # Managed application policies attach only to the intended task role.
  assert {
    condition = (
      toset(keys(aws_iam_role_policy_attachment.ecs_task_managed_policies)) == toset([
        "api|arn:aws:iam::123456789012:policy/api-read"
      ]) &&
      aws_iam_role_policy_attachment.ecs_task_managed_policies[
        "api|arn:aws:iam::123456789012:policy/api-read"
      ].role == aws_iam_role.ecs_task_roles["api"].name &&
      aws_iam_role_policy_attachment.ecs_task_managed_policies[
        "api|arn:aws:iam::123456789012:policy/api-read"
      ].policy_arn == "arn:aws:iam::123456789012:policy/api-read"
    )

    error_message = "Application managed policies must attach exclusively to their intended ECS task roles."
  }
}
# M1-N5C-A: reject unsafe inputs at the actual IAM interface before policy generation.

run "n5ca_reject_ssm_star" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["*"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_question" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["?"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_arn_star" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:us-east-1:123456789012:parameter/app/*"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_arn_question" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:us-east-1:123456789012:parameter/app/config?"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_region_wildcard" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:*:123456789012:parameter/app/config"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_account_wildcard" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:us-east-1:12345678901?:parameter/app/config"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_bare_path" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["/app/config"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_unsupported_partition" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:other:ssm:us-east-1:123456789012:parameter/app/config"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_wrong_resource" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:us-east-1:123456789012:document/app"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_ssm_empty_parameter" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:us-east-1:123456789012:parameter/"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_star" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["*"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_question" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["?"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_key_star" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/*"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_key_question" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/mrk-0123456789abcdef0123456789abcde?"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_region_wildcard" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:*:123456789012:key/mrk-0123456789abcdef0123456789abcdef"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_account_wildcard" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:12345678901?:key/mrk-0123456789abcdef0123456789abcdef"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_bare_id" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["22222222-2222-2222-2222-222222222222"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_alias_arn" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:alias/app"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_unsupported_partition" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:other:kms:us-east-1:123456789012:key/mrk-0123456789abcdef0123456789abcdef"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_empty_key" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_reject_kms_whitespace" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/ key"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "n5ca_accept_exact_ssm_and_kms_partition_arns" {
  command = plan

  variables {
    ecs_iam_services = {
      for partition, region in { aws = "us-east-1", aws-us-gov = "us-gov-west-1", aws-cn = "cn-north-1" } :
      partition => merge(var.ecs_iam_services.api, {
        execution_ssm_parameter_arns = ["arn:${partition}:ssm:${region}:123456789012:parameter/app/Config_1.2-test"]
        task_execution_kms_key_arns = [
          "arn:${partition}:kms:${region}:123456789012:key/22222222-2222-2222-2222-222222222222",
          "arn:${partition}:kms:${region}:123456789012:key/mrk-0123456789abcdef0123456789abcdef"
        ]

      })
    }
  }
  assert {
    condition = alltrue([
      for service_name, service in var.ecs_iam_services : alltrue([
        for expected in [
          { sid = "AllowSSMParameterRead", action = "ssm:GetParameters", resources = service.execution_ssm_parameter_arns },
          { sid = "AllowExecutionKMSDecrypt", action = "kms:Decrypt", resources = service.task_execution_kms_key_arns }
          ] : length([
            for statement in jsondecode(aws_iam_role_policy.ecs_task_execution_policies[service_name].policy).Statement : statement
            if statement.Sid == expected.sid &&
            toset(flatten([statement.Action])) == toset([expected.action]) &&
            toset(flatten([statement.Resource])) == expected.resources
        ]) == 1
      ])
    ])
    error_message = "All three AWS partitions must retain exact SSM and KMS key scopes, including multi-Region keys."
  }
}
