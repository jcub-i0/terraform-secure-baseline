
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


override_resource {
  target          = aws_sqs_queue.broker_completion[0]
  override_during = plan
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:unit-test-dev-job-broker-completion"
    url = "https://sqs.us-east-1.amazonaws.com/123456789012/unit-test-dev-job-broker-completion"
  }
}
override_resource {
  target          = aws_sqs_queue.broker_completion_dlq["delivery"]
  override_during = plan
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:unit-test-dev-job-completion-delivery-dlq"
    url = "https://sqs.us-east-1.amazonaws.com/123456789012/unit-test-dev-job-completion-delivery-dlq"
  }
}
override_resource {
  target          = aws_sqs_queue.broker_completion_dlq["processing"]
  override_during = plan
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:unit-test-dev-job-completion-processing-dlq"
    url = "https://sqs.us-east-1.amazonaws.com/123456789012/unit-test-dev-job-completion-processing-dlq"
  }
}
override_resource {
  target          = aws_cloudwatch_event_rule.broker_completion[0]
  override_during = plan
  values = {
    arn = "arn:aws:events:us-east-1:123456789012:rule/unit-test-dev-job-broker-completion"
  }
}

run "completion_defaults_absent" {
  command = plan

  assert {
    condition = (
      length(aws_sqs_queue.broker_completion) == 0 &&
      length(aws_sqs_queue.broker_completion_dlq) == 0 &&
      length(aws_sqs_queue_policy.broker_completion) == 0 &&
      length(aws_cloudwatch_event_rule.broker_completion) == 0 &&
      length(aws_cloudwatch_event_target.broker_completion) == 0 &&
      length(aws_lambda_event_source_mapping.broker_completion) == 0 &&
      output.broker_completion_delivery == null &&
      alltrue([
        for statement in data.aws_iam_policy_document.broker_runtime[0].statement :
        !contains(["ConsumeBrokerCompletion", "DecryptBrokerCompletion"], statement.sid)
      ])
    )
    error_message = "Existing callers must retain no completion resources or permissions by default."
  }
}

run "completion_transport" {
  command = plan

  variables {
    completion_delivery = {
      queue_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
      task_definition_family_arns = [
        "arn:aws:ecs:us-east-1:123456789012:task-definition/archive",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/report",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/retired-job"
      ]
    }
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.broker_completion[0].event_pattern) == {
      source        = ["aws.ecs"]
      "detail-type" = ["ECS Task State Change"]
      account       = ["123456789012"]
      region        = ["us-east-1"]
      detail = {
        clusterArn = [var.approved_cluster_arn]
        lastStatus = ["STOPPED"]
        taskDefinitionArn = [
          { prefix = "arn:aws:ecs:us-east-1:123456789012:task-definition/archive:" },
          { prefix = "arn:aws:ecs:us-east-1:123456789012:task-definition/report:" },
          { prefix = "arn:aws:ecs:us-east-1:123456789012:task-definition/retired-job:" }
        ]
      }
    }
    error_message = "Match only stopped tasks in the exact scope, retaining older revisions and retired families without prefix collisions."
  }

  assert {
    condition = (
      aws_cloudwatch_event_rule.broker_completion[0].state == "DISABLED" &&
      length(aws_lambda_event_source_mapping.broker_completion) == 0 &&
      aws_cloudwatch_event_target.broker_completion[0].input == null &&
      aws_cloudwatch_event_target.broker_completion[0].input_path == null &&
      length(aws_cloudwatch_event_target.broker_completion[0].input_transformer) == 0 &&
      aws_cloudwatch_event_target.broker_completion[0].arn == aws_sqs_queue.broker_completion[0].arn &&
      one(aws_cloudwatch_event_target.broker_completion[0].dead_letter_config).arn == aws_sqs_queue.broker_completion_dlq["delivery"].arn &&
      one(aws_cloudwatch_event_target.broker_completion[0].retry_policy).maximum_event_age_in_seconds == 86400
    )
    error_message = "Preserve the original event with bounded retries and a delivery DLQ; keep delivery disabled."
  }

  assert {
    condition = (
      aws_sqs_queue.broker_completion[0].kms_master_key_id == var.completion_delivery.queue_cmk_arn &&
      aws_sqs_queue.broker_completion[0].visibility_timeout_seconds == 360 &&
      aws_sqs_queue.broker_completion[0].message_retention_seconds == 345600 &&
      jsondecode(aws_sqs_queue.broker_completion[0].redrive_policy) == {
        deadLetterTargetArn = aws_sqs_queue.broker_completion_dlq["processing"].arn
        maxReceiveCount     = 5
      } &&
      jsondecode(aws_sqs_queue_redrive_allow_policy.broker_completion_processing[0].redrive_allow_policy) == {
        redrivePermission = "byQueue"
        sourceQueueArns   = [aws_sqs_queue.broker_completion[0].arn]
      } &&
      alltrue([
        for queue in values(aws_sqs_queue.broker_completion_dlq) :
        queue.kms_master_key_id == var.completion_delivery.queue_cmk_arn &&
        queue.message_retention_seconds == 1209600 &&
        queue.fifo_queue == false
      ])
    )
    error_message = "Use encrypted standard queues, six-timeout visibility and isolated processing redrive."
  }

  assert {
    condition = alltrue([
      for key in ["main", "delivery"] :
      { for s in data.aws_iam_policy_document.broker_completion_queue[key].statement : s.sid => {
        effect     = s.effect
        actions    = toset(s.actions)
        resources  = toset(s.resources)
        principals = { for p in s.principals : p.type => toset(p.identifiers) }
        conditions = { for c in s.condition : "${c.test}|${c.variable}" => toset(c.values) }
        } } == {
        DenyInsecureTransport = {
          effect     = "Deny"
          actions    = toset(["sqs:*"])
          resources  = toset([local.completion_queues[key].arn])
          principals = { "*" = toset(["*"]) }
          conditions = { "Bool|aws:SecureTransport" = toset(["false"]) }
        }
        AllowCompletionRule = {
          effect     = "Allow"
          actions    = toset(["sqs:SendMessage"])
          resources  = toset([local.completion_queues[key].arn])
          principals = { Service = toset(["events.amazonaws.com"]) }
          conditions = {
            "ArnEquals|aws:SourceArn"        = toset([aws_cloudwatch_event_rule.broker_completion[0].arn])
            "StringEquals|aws:SourceAccount" = toset(["123456789012"])
          }
        }
        DenyNonEventBridgeSenders = {
          effect     = "Deny"
          actions    = toset(["sqs:SendMessage"])
          resources  = toset([local.completion_queues[key].arn])
          principals = { "*" = toset(["*"]) }
          conditions = { "StringNotEqualsIfExists|aws:PrincipalServiceName" = toset(["events.amazonaws.com"]) }
        }
        DenyOtherCompletionRules = {
          effect     = "Deny"
          actions    = toset(["sqs:SendMessage"])
          resources  = toset([local.completion_queues[key].arn])
          principals = { "*" = toset(["*"]) }
          conditions = { "ArnNotEqualsIfExists|aws:SourceArn" = toset([aws_cloudwatch_event_rule.broker_completion[0].arn]) }
        }
      }
    ])
    error_message = "Queue submission must deny ordinary principals and other rules even if another policy grants SendMessage."
  }

  assert {
    condition = (
      length(aws_cloudwatch_metric_alarm.broker_completion_dlq_visible) == 2 &&
      alltrue([
        for purpose, alarm in aws_cloudwatch_metric_alarm.broker_completion_dlq_visible :
        alarm.dimensions.QueueName == aws_sqs_queue.broker_completion_dlq[purpose].name &&
        toset(alarm.alarm_actions) == toset([var.alarm_topic_arn])
      ]) &&
      aws_cloudwatch_metric_alarm.broker_completion_dlq_delivery_failed[0].metric_name == "InvocationsFailedToBeSentToDlq" &&
      aws_cloudwatch_metric_alarm.broker_completion_dlq_delivery_failed[0].dimensions.RuleName == aws_cloudwatch_event_rule.broker_completion[0].name
    )
    error_message = "Surface both failure queues and failure to preserve an event in the delivery DLQ."
  }
}

run "completion_consumer_disabled_and_scoped" {
  command = plan

  variables {
    completion_delivery = {
      queue_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
      task_definition_family_arns = [
        "arn:aws:ecs:us-east-1:123456789012:task-definition/archive",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/report"
      ]
    }
    broker_lambda_package = {
      bucket     = "unit-test-approved-artifacts"
      key        = "broker/release-1/broker.zip"
      version_id = "test-version-001"
    }
    broker_lambda_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
  }

  assert {
    condition = (
      aws_lambda_event_source_mapping.broker_completion[0].enabled == false &&
      aws_lambda_event_source_mapping.broker_completion[0].event_source_arn == aws_sqs_queue.broker_completion[0].arn &&
      aws_lambda_event_source_mapping.broker_completion[0].batch_size == 1 &&
      aws_lambda_event_source_mapping.broker_completion[0].maximum_batching_window_in_seconds == 0 &&
      aws_lambda_function.broker[0].reserved_concurrent_executions == 0 &&
      aws_lambda_function.broker[0].timeout == 60 &&
      aws_lambda_event_source_mapping.broker_requests[0].enabled == false
    )
    error_message = "Both mappings and Lambda concurrency must stay closed pending qualification."
  }

  assert {
    condition = {
      for s in data.aws_iam_policy_document.broker_runtime[0].statement : s.sid => {
        effect     = s.effect
        actions    = toset(s.actions)
        resources  = toset(s.resources)
        conditions = { for c in s.condition : "${c.test}|${c.variable}" => toset(c.values) }
      } if contains(["ConsumeBrokerCompletion", "DecryptBrokerCompletion"], s.sid)
      } == {
      ConsumeBrokerCompletion = {
        effect     = "Allow"
        actions    = toset(["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"])
        resources  = toset([aws_sqs_queue.broker_completion[0].arn])
        conditions = {}
      }
      DecryptBrokerCompletion = {
        effect    = "Allow"
        actions   = toset(["kms:Decrypt"])
        resources = toset([var.completion_delivery.queue_cmk_arn])
        conditions = {
          "StringEquals|kms:ViaService"                    = toset(["sqs.us-east-1.amazonaws.com"])
          "StringEquals|kms:EncryptionContext:aws:sqs:arn" = toset([aws_sqs_queue.broker_completion[0].arn])
        }
      }
    }
    error_message = "Grant only consumption of the completion queue and its scoped KMS decrypt; no send, DLQ or replay authority."
  }
}

run "reject_other_account_family" {
  command = plan
  variables {
    completion_delivery = {
      queue_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
      task_definition_family_arns = [
        "arn:aws:ecs:us-east-1:123456789012:task-definition/archive",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/report",
        "arn:aws:ecs:us-east-1:999999999999:task-definition/unrelated"
      ]
    }
  }
  expect_failures = [var.completion_delivery]
}

run "reject_wildcard_family" {
  command = plan
  variables {
    completion_delivery = {
      queue_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
      task_definition_family_arns = [
        "arn:aws:ecs:us-east-1:123456789012:task-definition/archive",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/report",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/*"
      ]
    }
  }
  expect_failures = [var.completion_delivery]
}

run "reject_revision_scoped_completion" {
  command = plan
  variables {
    completion_delivery = {
      queue_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
      task_definition_family_arns = [
        "arn:aws:ecs:us-east-1:123456789012:task-definition/archive:3",
        "arn:aws:ecs:us-east-1:123456789012:task-definition/report:5"
      ]
    }
  }
  expect_failures = [var.completion_delivery]
}

run "reject_omitted_current_job" {
  command = plan
  variables {
    completion_delivery = {
      queue_cmk_arn               = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
      task_definition_family_arns = ["arn:aws:ecs:us-east-1:123456789012:task-definition/archive"]
    }
  }
  expect_failures = [var.completion_delivery]
}
