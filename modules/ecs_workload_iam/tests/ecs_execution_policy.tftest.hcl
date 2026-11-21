provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name_prefix    = "unit-test-dev"
  environment    = "dev"
  account_id     = "123456789012"
  primary_region = "us-east-1"

  workloads = {
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
    workloads = {}
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

  assert {
    condition = (
      length(output.execution_roles) == 0 &&
      length(output.task_roles) == 0 &&
      length(output.execution_policy_ids) == 0 &&
      length(output.task_role_policy_attachment_ids) == 0
    )

    error_message = "An empty workload map must produce four empty IAM output contracts."
  }
}

run "multi_service_iam_isolation" {
  command = plan

  variables {
    workloads = {
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
      for service_name, service in var.workloads :
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

  # Four independent output contracts. Attachment readiness omits workloads
  # without task-role managed policies; IDs are unknown until apply.
  assert {
    condition = (
      output.execution_roles["api"].name == "unit-test-dev-api-ecs-execution" &&
      output.execution_roles["worker"].name == "unit-test-dev-worker-ecs-execution" &&
      output.task_roles["api"].name == "unit-test-dev-api-ecs-task" &&
      output.task_roles["worker"].name == "unit-test-dev-worker-ecs-task" &&
      toset(keys(output.execution_roles["api"])) == toset(["arn", "name"]) &&
      toset(keys(output.task_roles["api"])) == toset(["arn", "name"]) &&
      toset(keys(output.execution_policy_ids)) == toset(["api", "worker"]) &&
      toset(keys(output.task_role_policy_attachment_ids)) == toset(["api"])
    )

    error_message = "Role, execution-policy readiness, and opted-in task-role attachment readiness outputs must keep their keys and shapes."
  }
}

run "n5ca_reject_ssm_arn_star" {
  command = plan

  variables {
    workloads = {
      api = merge(var.workloads.api, {
        execution_ssm_parameter_arns = ["arn:aws:ssm:us-east-1:123456789012:parameter/app/*"]
      })
    }
  }

  expect_failures = [var.workloads]
}

run "n5ca_reject_kms_key_star" {
  command = plan

  variables {
    workloads = {
      api = merge(var.workloads.api, {
        task_execution_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/*"]
      })
    }
  }

  expect_failures = [var.workloads]
}

run "reject_secret_wildcard_suffix" {
  command = plan

  variables {
    workloads = {
      api = merge(var.workloads.api, {
        execution_secret_arns = [
          "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-*"
        ]
      })
    }
  }

  expect_failures = [var.workloads]
}

run "reject_ecr_wildcard_resource" {
  command = plan

  variables {
    workloads = {
      api = merge(var.workloads.api, {
        ecr_repository_arns = ["*"]
      })
    }
  }

  expect_failures = [var.workloads]
}

run "reject_guardduty_ecr_repository_wildcard" {
  command = plan

  variables {
    workloads = {
      api = merge(var.workloads.api, {
        guardduty_agent_ecr_repository_arns = ["arn:aws:ecr:us-east-1:987654321098:repository/aws-guardduty-agent*"]
      })
    }
  }

  expect_failures = [var.workloads]
}

run "reject_cross_account_task_policy" {
  command = plan

  variables {
    workloads = {
      api = merge(var.workloads.api, {
        task_role_managed_policy_arns = ["arn:aws:iam::987654321098:policy/application"]
      })
    }
  }

  expect_failures = [aws_iam_role_policy_attachment.ecs_task_managed_policies]
}

# One direct consumer: standalone ECS jobs composed with shared workload IAM.
# A completed plan proves the composition has no dependency cycle.
run "ecs_task_composition_without_cycle" {
  command = plan

  module {
    source = "./tests/fixtures/ecs_task_composition"
  }

  assert {
    condition = alltrue([
      for job_name, log_group in output.job_log_groups :
      output.iam_log_group_arns[job_name] == toset([
        "arn:aws:logs:us-east-1:123456789012:log-group:${log_group.name}"
      ])
    ]) && toset(keys(output.job_log_groups)) == toset(["archive", "report"])

    error_message = "Deterministic IAM log-group ARNs must match the log groups created by ecs_task."
  }

  assert {
    condition = (
      toset(keys(output.execution_policy_ids)) == toset(["archive", "report"]) &&
      length(output.task_role_policy_attachment_ids) == 0
    )

    error_message = "Job IAM must expose execution-policy readiness and omit attachment readiness without managed policies."
  }

  assert {
    condition = (
      toset(keys(output.launcher_policy_roles)) ==
      toset(["archive", "report"]) &&
      output.launcher_policy_roles["archive"] ==
      "unit-test-dev-archive-launcher" &&
      output.launcher_policy_roles["report"] ==
      "unit-test-dev-report-launcher"
    )

    error_message = "Each synthetic job must have its own launcher role and policy."
  }
}
