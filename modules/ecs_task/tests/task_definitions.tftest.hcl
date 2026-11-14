mock_provider "aws" {}

variables {
  name_prefix    = "unit-test"
  environment    = "dev"
  primary_region = "us-east-1"

  cloudwatch_retention_days = 14

  logs_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
}

run "empty_tasks" {
  command = plan

  assert {
    condition = (
      length(aws_ecs_task_definition.jobs) == 0 &&
      length(aws_cloudwatch_log_group.job_logs) == 0
    )

    error_message = "Empty tasks must create no task definitions or log groups."
  }
}

run "independent_jobs" {
  command = plan

  variables {
    tasks = {
      alpha = {
        image              = "worker-alpha@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        cpu                = 256
        memory             = 512
        execution_role_arn = "arn:aws:iam::123456789012:role/alpha-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/alpha-task"
        command            = ["sh", "-c", "echo alpha"]
      }

      beta = {
        image              = "worker-beta@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        cpu                = 512
        memory             = 1024
        execution_role_arn = "arn:aws:iam::123456789012:role/beta-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/beta-task"
      }
    }
  }

  assert {
    condition = (
      length(aws_ecs_task_definition.jobs) == 2 &&
      length(aws_cloudwatch_log_group.job_logs) == 2
    )

    error_message = "Two jobs must produce two task definitions and log groups."
  }

  assert {
    condition = (
      aws_ecs_task_definition.jobs["alpha"].task_role_arn !=
      aws_ecs_task_definition.jobs["beta"].task_role_arn
      &&
      aws_ecs_task_definition.jobs["alpha"].execution_role_arn !=
      aws_ecs_task_definition.jobs["beta"].execution_role_arn
    )

    error_message = "Jobs must retain independent task and execution role references."
  }

  assert {
    condition = (
      jsondecode(
        aws_ecs_task_definition.jobs["alpha"].container_definitions
      )[0].command == ["sh", "-c", "echo alpha"]
      &&
      jsondecode(
        aws_ecs_task_definition.jobs["alpha"].container_definitions
      )[0].logConfiguration.options["awslogs-group"] ==
      aws_cloudwatch_log_group.job_logs["alpha"].name
      &&
      aws_cloudwatch_log_group.job_logs["alpha"].kms_key_id == var.logs_cmk_arn
    )

    error_message = "Job command, logging configuration or KMS association is incorrect."
  }
}

run "reject_mutable_image" {
  command = plan

  variables {
    tasks = {
      alpha = {
        image              = "worker-alpha:latest"
        cpu                = 256
        memory             = 512
        execution_role_arn = "arn:aws:iam::123456789012:role/alpha-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/alpha-task"
      }
    }
  }

  expect_failures = [var.tasks]
}
