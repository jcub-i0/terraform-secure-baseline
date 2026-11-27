
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
  target          = aws_sqs_queue.broker_requests[0]
  override_during = plan
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:unit-test-dev-job-broker-requests"
    url = "https://sqs.us-east-1.amazonaws.com/123456789012/unit-test-dev-job-broker-requests"
  }
}

run "default_denies_all_request_submissions" {
  command = plan

  assert {
    condition = {
      for statement in data.aws_iam_policy_document.broker_queue_transport[0].statement :
      statement.sid => {
        effect    = statement.effect
        actions   = toset(statement.actions)
        resources = toset(statement.resources)
        principals = {
          for principal in statement.principals :
          principal.type => toset(principal.identifiers)
        }
        conditions = {
          for condition in statement.condition :
          "${condition.test}|${condition.variable}" => toset(condition.values)
        }
      }
      } == {
      DenyInsecureTransport = {
        effect     = "Deny"
        actions    = toset(["sqs:*"])
        resources  = toset([aws_sqs_queue.broker_requests[0].arn])
        principals = { "*" = toset(["*"]) }
        conditions = { "Bool|aws:SecureTransport" = toset(["false"]) }
      }
      DenyUnapprovedRequestProducers = {
        effect     = "Deny"
        actions    = toset(["sqs:SendMessage"])
        resources  = toset([aws_sqs_queue.broker_requests[0].arn])
        principals = { "*" = toset(["*"]) }
        conditions = {}
      }
    }
    error_message = "With no producers configured, request submission must be unconditionally denied while TLS protection remains."
  }

  assert {
    condition     = aws_sqs_queue_policy.broker_requests[0].queue_url == aws_sqs_queue.broker_requests[0].url
    error_message = "The policy must remain attached to the exact request queue."
  }
}

run "approved_role_arns_scope_request_submissions" {
  command = plan

  variables {
    request_producer_role_arns = [
      "arn:aws:iam::123456789012:role/unit-test-dev-report-scheduler-execution",
      "arn:aws:iam::123456789012:role/application/producers/on-demand"
    ]
  }

  assert {
    condition = {
      for statement in data.aws_iam_policy_document.broker_queue_transport[0].statement :
      statement.sid => {
        effect    = statement.effect
        actions   = toset(statement.actions)
        resources = toset(statement.resources)
        principals = {
          for principal in statement.principals :
          principal.type => toset(principal.identifiers)
        }
        conditions = {
          for condition in statement.condition :
          "${condition.test}|${condition.variable}" => toset(condition.values)
        }
      }
      } == {
      DenyInsecureTransport = {
        effect     = "Deny"
        actions    = toset(["sqs:*"])
        resources  = toset([aws_sqs_queue.broker_requests[0].arn])
        principals = { "*" = toset(["*"]) }
        conditions = { "Bool|aws:SecureTransport" = toset(["false"]) }
      }
      DenyUnapprovedRequestProducers = {
        effect     = "Deny"
        actions    = toset(["sqs:SendMessage"])
        resources  = toset([aws_sqs_queue.broker_requests[0].arn])
        principals = { "*" = toset(["*"]) }
        conditions = {
          "ArnNotEqualsIfExists|aws:PrincipalArn" = var.request_producer_role_arns
        }
      }
    }
    error_message = "Only the configured IAM role ARNs may escape the submission deny; missing identity remains denied and no Allow is added."
  }

  assert {
    condition = (
      length(aws_lambda_function.broker) == 0 &&
      length(aws_lambda_event_source_mapping.broker_requests) == 0 &&
      length(aws_cloudwatch_event_rule.broker_completion) == 0
    )
    error_message = "Configuring producer roles must not create or activate runtime delivery."
  }
}

run "reject_wildcard_request_producer" {
  command = plan
  variables {
    request_producer_role_arns = [
      "arn:aws:iam::123456789012:role/application/*"
    ]
  }
  expect_failures = [var.request_producer_role_arns]
}

run "reject_cross_account_request_producer" {
  command = plan
  variables {
    request_producer_role_arns = [
      "arn:aws:iam::999999999999:role/on-demand"
    ]
  }
  expect_failures = [var.request_producer_role_arns]
}

run "reject_session_arn_as_request_producer" {
  command = plan
  variables {
    request_producer_role_arns = [
      "arn:aws:sts::123456789012:assumed-role/on-demand/session-name"
    ]
  }
  expect_failures = [var.request_producer_role_arns]
}
