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

        guardduty_agent_ecr_repository_arns = [
          "arn:aws:ecr:us-east-1:987654321098:repository/aws-guardduty-agent-fargate"
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

  # Compare every service independently, including present and absent optional
  # grants. The GuardDuty repository intentionally belongs to another account.
  assert {
    condition = alltrue([
      for service_name, service in var.ecs_iam_services :
      try(
        jsondecode(aws_iam_role_policy.ecs_task_execution_policies[service_name].policy).Version == "2012-10-17" &&
        alltrue([
          for statement in jsondecode(aws_iam_role_policy.ecs_task_execution_policies[service_name].policy).Statement :
          toset(keys(statement)) == toset(["Sid", "Effect", "Action", "Resource"])
        ]) &&
        { for statement in jsondecode(aws_iam_role_policy.ecs_task_execution_policies[service_name].policy).Statement : statement.Sid => {
          effect    = statement.Effect
          actions   = toset(flatten([statement.Action]))
          resources = toset(flatten([statement.Resource]))
          } } == { for sid, expected in {
          AllowECRAuthorization = {
            effect    = "Allow"
            actions   = toset(["ecr:GetAuthorizationToken"])
            resources = toset(["*"])
          }
          AllowECRImagePulls = {
            effect    = "Allow"
            actions   = toset(["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"])
            resources = service.ecr_repository_arns
          }
          AllowCloudWatchLogWrites = {
            effect    = "Allow"
            actions   = toset(["logs:CreateLogStream", "logs:PutLogEvents"])
            resources = toset([for arn in service.log_group_arns : "${arn}:*"])
          }
          AllowSecretsManagerRead = {
            effect    = "Allow"
            actions   = toset(["secretsmanager:GetSecretValue"])
            resources = service.execution_secret_arns
          }
          AllowSSMParameterRead = {
            effect    = "Allow"
            actions   = toset(["ssm:GetParameters"])
            resources = service.execution_ssm_parameter_arns
          }
          AllowExecutionKMSDecrypt = {
            effect    = "Allow"
            actions   = toset(["kms:Decrypt"])
            resources = service.task_execution_kms_key_arns
          }
          AllowGuardDutyAgentImagePulls = {
            effect    = "Allow"
            actions   = toset(["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"])
            resources = service.guardduty_agent_ecr_repository_arns
          }
        } : sid => expected if length(expected.resources) > 0 },
        false
      )
    ])
    error_message = "Each generated execution policy must contain exactly its allowed statements, effects, actions, and resources, including optional GuardDuty pulls."
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

run "reject_secret_wildcard_suffix" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        execution_secret_arns = [
          "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-*"
        ]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "reject_ecr_wildcard_resource" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        ecr_repository_arns = ["*"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "reject_guardduty_ecr_repository_wildcard" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        guardduty_agent_ecr_repository_arns = ["arn:aws:ecr:us-east-1:987654321098:repository/aws-guardduty-agent*"]
      })
    }
  }

  expect_failures = [var.ecs_iam_services]
}

run "reject_cross_account_task_policy" {
  command = plan

  variables {
    ecs_iam_services = {
      api = merge(var.ecs_iam_services.api, {
        task_role_managed_policy_arns = ["arn:aws:iam::987654321098:policy/application"]
      })
    }
  }

  expect_failures = [aws_iam_role_policy_attachment.ecs_task_managed_policies]
}
