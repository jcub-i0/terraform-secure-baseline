provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name_prefix = "unit-test-dev"
  environment = "dev"

  broker_request_queue_arn = "arn:aws:sqs:us-east-1:123456789012:broker-requests"

  dlq_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  broker_request_queue_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  alarm_topic_arn = "arn:aws:sns:us-east-1:123456789012:application-alerts"
}

# Prevent AWS STS calls across all test runs.
override_data {
  target          = data.aws_caller_identity.current
  override_during = plan

  values = {
    account_id = "123456789012"
  }
}

run "empty_schedules" {
  command = plan

  assert {
    condition = (
      length(aws_scheduler_schedule_group.jobs) == 0 &&
      length(aws_scheduler_schedule.jobs) == 0 &&
      length(aws_sqs_queue.scheduler_dlq) == 0 &&
      length(aws_iam_role.scheduler_execution) == 0 &&
      length(aws_iam_role_policy.scheduler_delivery) == 0 &&
      length(aws_cloudwatch_metric_alarm.scheduler_dlq_visible) == 0 &&
      output.schedule_group == null &&
      length(output.schedules) == 0
    )

    error_message = "Empty schedules must create no Scheduler-owned resources."
  }
}

run "independent_disabled_schedules" {
  command = plan

  variables {
    schedules = {
      archive = {
        job_key             = "archive"
        schedule_expression = "rate(1 day)"
      }

      report = {
        job_key             = "report"
        schedule_expression = "cron(0 8 * * ? *)"
      }
    }
  }

  assert {
    condition = (
      toset(keys(aws_scheduler_schedule.jobs)) ==
      toset(["archive", "report"]) &&
      toset(keys(aws_sqs_queue.scheduler_dlq)) ==
      toset(["archive", "report"]) &&
      toset(keys(aws_iam_role.scheduler_execution)) ==
      toset(["archive", "report"]) &&
      toset(keys(aws_cloudwatch_metric_alarm.scheduler_dlq_visible)) ==
      toset(["archive", "report"])
    )

    error_message = "Each schedule must have its own IAM role, DLQ, and alarm."
  }

  assert {
    condition = alltrue([
      for name, schedule in aws_scheduler_schedule.jobs :
      schedule.state == "DISABLED" &&
      schedule.target[0].arn == var.broker_request_queue_arn &&
      jsondecode(schedule.target[0].input).job_key ==
      var.schedules[name].job_key
    ])

    error_message = "Schedules must remain disabled and target the configured broker queue."
  }

  assert {
    condition = alltrue([
      for name, queue in aws_sqs_queue.scheduler_dlq :
      queue.kms_master_key_id == var.dlq_kms_key_arn &&
      aws_cloudwatch_metric_alarm.scheduler_dlq_visible[name].dimensions["QueueName"] ==
      queue.name
    ])

    error_message = "Each DLQ must use the configured CMK and have its own alarm."
  }

  assert {
    condition = alltrue([
      for name, schedule in aws_scheduler_schedule.jobs :
      strcontains(
        schedule.target[0].input,
        "<aws.scheduler.schedule-arn>"
      ) &&
      strcontains(
        schedule.target[0].input,
        "<aws.scheduler.scheduled-time>"
      ) &&
      try(
        jsondecode(schedule.target[0].input).schedule_arn ==
        "<aws.scheduler.schedule-arn>" &&
        jsondecode(schedule.target[0].input).scheduled_time ==
        "<aws.scheduler.scheduled-time>" &&
        jsondecode(schedule.target[0].input).request_key ==
        "<aws.scheduler.schedule-arn>|<aws.scheduler.scheduled-time>",
        false
      )
    ])

    error_message = "Scheduler input must retain literal context tokens and valid JSON request fields."
  }
}

run "reject_missing_broker_queue" {
  command = plan

  variables {
    broker_request_queue_arn = null

    schedules = {
      archive = {
        job_key             = "archive"
        schedule_expression = "rate(1 day)"
      }
    }
  }

  expect_failures = [var.broker_request_queue_arn]
}

run "reject_missing_dlq_cmk" {
  command = plan

  variables {
    dlq_kms_key_arn = null

    schedules = {
      archive = {
        job_key             = "archive"
        schedule_expression = "rate(1 day)"
      }
    }
  }

  expect_failures = [var.dlq_kms_key_arn]
}

run "reject_invalid_schedule_configuration" {
  command = plan

  variables {
    schedules = {
      archive = {
        job_key                = "archive"
        schedule_expression    = "invalid-expression"
        maximum_retry_attempts = 186
      }
    }
  }

  expect_failures = [var.schedules]
}