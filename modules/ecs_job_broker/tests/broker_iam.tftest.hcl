
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

  approved_cluster_arn = "arn:aws:ecs:us-east-1:123456789012:cluster/unit-test-dev"

  permissions_boundary_arn     = "arn:aws:iam::123456789012:policy/approved-workload-boundary"
  broker_request_queue_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  execution_ledger_cmk_arn     = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  broker_log_cmk_arn           = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"

  cloudwatch_retention_days = 30
  alarm_topic_arn           = "arn:aws:sns:us-east-1:123456789012:application-alerts"

  jobs = {
    archive = {
      task_definition_arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/archive:3"
      execution_role_arn  = "arn:aws:iam::123456789012:role/archive-execution"
      task_role_arn       = "arn:aws:iam::123456789012:role/archive-task"
    }

    report = {
      task_definition_arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/report:5"
      execution_role_arn  = "arn:aws:iam::123456789012:role/report-execution"
      task_role_arn       = "arn:aws:iam::123456789012:role/report-task"
    }
  }
}

run "empty_jobs" {
  command = plan

  variables {
    jobs = {}
  }

  assert {
    condition = (
      length(aws_sqs_queue.broker_processing_dlq) == 0 &&
      length(aws_sqs_queue_redrive_allow_policy.broker_processing_dlq) == 0 &&
      length(aws_sqs_queue_policy.broker_processing_dlq) == 0 &&
      length(aws_lambda_event_source_mapping.broker_requests) == 0 &&
      output.broker_processing_dlq == null &&
      output.broker_event_source_mapping_uuid == null &&
      length(aws_lambda_function.broker) == 0 &&
      output.broker_lambda == null &&
      length(aws_cloudwatch_log_group.broker) == 0 &&
      length(aws_iam_role_policy.broker_runtime) == 0 &&
      output.broker_log_group == null &&
      length(aws_dynamodb_table.execution_ledger) == 0 &&
      output.execution_ledger == null &&
      length(aws_sqs_queue.broker_requests) == 0 &&
      length(aws_sqs_queue_policy.broker_requests) == 0 &&
      output.broker_request_queue == null &&
      length(aws_iam_role.broker_execution) == 0 &&
      length(aws_iam_role.launcher) == 0 &&
      length(aws_iam_role_policy.broker_assume_launchers) == 0 &&
      length(aws_iam_role_policy.job_launch) == 0 &&
      output.broker_execution_role == null &&
      length(output.launcher_roles) == 0
    )

    error_message = "Empty jobs must not create broker or launcher IAM resources."
  }
}

run "two_job_iam_contract" {
  command = plan

  assert {
    condition = (
      length(aws_iam_role.broker_execution) == 1 &&
      toset(keys(aws_iam_role.launcher)) == toset(["archive", "report"]) &&
      toset(keys(aws_iam_role_policy.job_launch)) == toset(["archive", "report"]) &&
      aws_iam_role.broker_execution[0].permissions_boundary == var.permissions_boundary_arn &&
      alltrue([
        for role in values(aws_iam_role.launcher) :
        role.permissions_boundary == var.permissions_boundary_arn
      ])
    )

    error_message = "Broker and separate launchers must retain mandatory boundaries."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.broker_trust.statement) == 1 &&
      toset(data.aws_iam_policy_document.broker_trust.statement[0].actions) ==
      toset(["sts:AssumeRole"]) &&
      toset(one(data.aws_iam_policy_document.broker_trust.statement[0].principals).identifiers) ==
      toset(["lambda.amazonaws.com"]) &&
      length(data.aws_iam_policy_document.broker_assume_launchers[0].statement) == 1 &&
      toset(data.aws_iam_policy_document.broker_assume_launchers[0].statement[0].actions) ==
      toset(["sts:AssumeRole"])
    )

    error_message = "Broker trust and launcher-assumption actions must remain scoped."
  }

  assert {
    condition = alltrue([
      for job_key, job in var.jobs :
      {
        for s in data.aws_iam_policy_document.job_launch[job_key].statement :
        s.sid => {
          effect    = s.effect
          actions   = toset(s.actions)
          resources = toset(s.resources)
          conditions = {
            for c in s.condition :
            "${c.test}|${c.variable}" => toset(c.values)
          }
        }
        } == {
        RunApprovedTaskRevision = {
          effect    = "Allow"
          actions   = toset(["ecs:RunTask"])
          resources = toset([job.task_definition_arn])
          conditions = {
            "ArnEquals|ecs:cluster" = toset([var.approved_cluster_arn])
          }
        }

        PassOnlyApprovedJobRoles = {
          effect  = "Allow"
          actions = toset(["iam:PassRole"])
          resources = toset([
            job.execution_role_arn,
            job.task_role_arn
          ])
          conditions = {
            "StringEquals|iam:PassedToService" = toset([
              "ecs-tasks.amazonaws.com"
            ])
          }
        }
      }
    ])

    error_message = "Each job must retain exact revision, cluster, and PassRole authorization."
  }

  assert {
    condition = (
      length(aws_sqs_queue.broker_requests) == 1 &&
      aws_sqs_queue.broker_requests[0].fifo_queue == false &&
      aws_sqs_queue.broker_requests[0].kms_master_key_id ==
      var.broker_request_queue_cmk_arn &&
      aws_sqs_queue.broker_requests[0].visibility_timeout_seconds == 360 &&
      aws_sqs_queue.broker_requests[0].message_retention_seconds == 345600 &&
      length(aws_sqs_queue_policy.broker_requests) == 1
    )

    error_message = "Configured jobs must create one encrypted standard broker request queue with its transport policy."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.broker_queue_transport[0].statement) == 1 &&
      data.aws_iam_policy_document.broker_queue_transport[0].statement[0].effect == "Deny" &&
      toset(data.aws_iam_policy_document.broker_queue_transport[0].statement[0].actions) ==
      toset(["sqs:*"]) &&
      alltrue([
        for condition in data.aws_iam_policy_document.broker_queue_transport[0].statement[0].condition :
        condition.test == "Bool" &&
        condition.variable == "aws:SecureTransport" &&
        toset(condition.values) == toset(["false"])
      ])
    )

    error_message = "Broker request queue must deny insecure transport."
  }

  assert {
    condition = (
      length(aws_dynamodb_table.execution_ledger) == 1 &&
      aws_dynamodb_table.execution_ledger[0].billing_mode == "PAY_PER_REQUEST" &&
      aws_dynamodb_table.execution_ledger[0].hash_key == "pk" &&
      aws_dynamodb_table.execution_ledger[0].deletion_protection_enabled == true &&
      length(aws_dynamodb_table.execution_ledger[0].point_in_time_recovery) == 1
    )

    error_message = "Configured jobs must create an on-demand execution ledger with recovery and deletion protection."
  }

  assert {
    condition = (
      length(aws_cloudwatch_log_group.broker) == 1 &&
      aws_cloudwatch_log_group.broker[0].retention_in_days ==
      var.cloudwatch_retention_days &&
      aws_cloudwatch_log_group.broker[0].kms_key_id ==
      var.broker_log_cmk_arn &&
      length(aws_iam_role_policy.broker_runtime) == 1 &&
      alltrue([
        for statement in data.aws_iam_policy_document.broker_runtime[0].statement :
        !contains(statement.actions, "ecs:RunTask") &&
        !contains(statement.actions, "iam:PassRole")
      ])
    )

    error_message = "Broker runtime must have encrypted logging and no direct ECS launch permissions."
  }

  assert {
    condition = (
      length(aws_lambda_function.broker) == 0 &&
      output.broker_lambda == null
    )

    error_message = "The broker Lambda must remain absent without an approved deployment package."
  }

  assert {
    condition = (
      length(aws_sqs_queue.broker_processing_dlq) == 1 &&
      aws_sqs_queue.broker_processing_dlq[0].kms_master_key_id ==
      var.broker_request_queue_cmk_arn &&
      aws_sqs_queue.broker_processing_dlq[0].message_retention_seconds == 1209600 &&
      length(aws_sqs_queue_redrive_allow_policy.broker_processing_dlq) == 1 &&
      length(aws_sqs_queue_policy.broker_processing_dlq) == 1 &&
      length(aws_lambda_event_source_mapping.broker_requests) == 0
    )

    error_message = "Configured jobs must have an encrypted processing DLQ; no event-source mapping may exist without a Lambda package."
  }

  assert {
    condition = (
      length(aws_cloudwatch_metric_alarm.broker_processing_dlq_visible) == 1 &&
      aws_cloudwatch_metric_alarm.broker_processing_dlq_visible[0].metric_name ==
      "ApproximateNumberOfMessagesVisible" &&
      aws_cloudwatch_metric_alarm.broker_processing_dlq_visible[0].threshold == 0 &&
      one(aws_cloudwatch_metric_alarm.broker_processing_dlq_visible[0].alarm_actions) ==
      var.alarm_topic_arn
    )

    error_message = "Broker processing DLQ must have an SNS-backed failure alarm."
  }
}

run "reject_missing_broker_queue_cmk" {
  command = plan

  variables {
    broker_request_queue_cmk_arn = null
  }

  expect_failures = [
    var.broker_request_queue_cmk_arn
  ]
}

run "reject_missing_execution_ledger_cmk" {
  command = plan

  variables {
    execution_ledger_cmk_arn = null
  }

  expect_failures = [
    var.execution_ledger_cmk_arn
  ]
}

run "reject_missing_broker_log_cmk" {
  command = plan

  variables {
    broker_log_cmk_arn = null
  }

  expect_failures = [
    var.broker_log_cmk_arn
  ]
}

run "reject_missing_cloudwatch_retention_days" {
  command = plan

  variables {
    cloudwatch_retention_days = null
  }

  expect_failures = [
    var.cloudwatch_retention_days
  ]
}

run "versioned_broker_lambda" {
  command = plan

  variables {
    broker_lambda_package = {
      bucket     = "unit-test-approved-artifacts"
      key        = "broker/release-1/broker.zip"
      version_id = "test-version-001"
    }

    broker_lambda_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
  }

  assert {
    condition = (
      length(aws_lambda_function.broker) == 1 &&
      aws_lambda_function.broker[0].reserved_concurrent_executions == 0 &&
      aws_lambda_function.broker[0].runtime == "python3.12" &&
      aws_lambda_function.broker[0].handler == "broker.lambda_handler" &&
      aws_lambda_function.broker[0].timeout == 60 &&
      aws_lambda_function.broker[0].s3_bucket == var.broker_lambda_package.bucket &&
      aws_lambda_function.broker[0].s3_key == var.broker_lambda_package.key &&
      aws_lambda_function.broker[0].s3_object_version == var.broker_lambda_package.version_id &&
      aws_lambda_function.broker[0].kms_key_arn == var.broker_lambda_cmk_arn
    )

    error_message = "Broker Lambda must use an exact S3 artifact version and remain disabled."
  }

  assert {
    condition = (
      length(aws_lambda_event_source_mapping.broker_requests) == 1 &&
      aws_lambda_event_source_mapping.broker_requests[0].enabled == false &&
      aws_lambda_event_source_mapping.broker_requests[0].batch_size == 1 &&
      aws_lambda_event_source_mapping.broker_requests[0].maximum_batching_window_in_seconds == 0
    )

    error_message = "Broker Lambda event-source mapping must remain disabled and use one-message batches."
  }
}

run "default_has_no_gate_permissions" {
  command = plan

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.broker_runtime[0].statement :
      !contains(["ReadAdmissionGate", "DecryptAdmissionGate"], statement.sid)
    ])
    error_message = "Omitting the gate must preserve the existing runtime permissions."
  }
}

run "scoped_admission_gate_permissions" {
  command = plan

  variables {
    admission_gate = {
      table_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/platform-app-dev-job-admission-gate"
      cmk_arn   = "arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444"
    }
    broker_lambda_package = {
      bucket     = "unit-test-approved-artifacts"
      key        = "broker/release-1/broker.zip"
      version_id = "test-version-001"
    }
    broker_lambda_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
  }

  assert {
    condition = {
      for statement in data.aws_iam_policy_document.broker_runtime[0].statement :
      statement.sid => {
        effect    = statement.effect
        actions   = toset(statement.actions)
        resources = toset(statement.resources)
        conditions = {
          for condition in statement.condition :
          "${condition.test}|${condition.variable}" => toset(condition.values)
        }
      } if contains(["ReadAdmissionGate", "DecryptAdmissionGate"], statement.sid)
      } == {
      ReadAdmissionGate = {
        effect     = "Allow"
        actions    = toset(["dynamodb:GetItem", "dynamodb:ConditionCheckItem"])
        resources  = toset([var.admission_gate.table_arn])
        conditions = {}
      }
      DecryptAdmissionGate = {
        effect    = "Allow"
        actions   = toset(["kms:Decrypt"])
        resources = toset([var.admission_gate.cmk_arn])
        conditions = {
          "StringEquals|kms:ViaService"                                  = toset(["dynamodb.us-east-1.amazonaws.com"])
          "StringEquals|kms:EncryptionContext:aws:dynamodb:tableName"    = toset(["platform-app-dev-job-admission-gate"])
          "StringEquals|kms:EncryptionContext:aws:dynamodb:subscriberId" = toset(["123456789012"])
        }
      }
    }
    error_message = "Gate grants must be read/condition-check only, with exact table/key and DynamoDB encryption-context scopes."
  }

  assert {
    condition = (
      aws_lambda_function.broker[0].reserved_concurrent_executions == 0 &&
      aws_lambda_event_source_mapping.broker_requests[0].enabled == false
    )
    error_message = "Gate configuration must not activate the broker."
  }
}

run "reject_wildcard_gate" {
  command = plan
  variables {
    admission_gate = {
      table_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/*"
      cmk_arn   = "arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444"
    }
  }
  expect_failures = [var.admission_gate]
}

run "reject_cross_account_gate" {
  command = plan
  variables {
    admission_gate = {
      table_arn = "arn:aws:dynamodb:us-east-1:999999999999:table/platform-app-dev-job-admission-gate"
      cmk_arn   = "arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444"
    }
  }
  expect_failures = [var.admission_gate]
}

run "reject_ledger_as_gate" {
  command = plan
  variables {
    admission_gate = {
      table_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/unit-test-dev-job-execution-ledger"
      cmk_arn   = "arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444"
    }
  }
  expect_failures = [var.admission_gate]
}
