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
