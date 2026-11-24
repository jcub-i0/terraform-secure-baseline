
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
      aws_sqs_queue.broker_requests[0].visibility_timeout_seconds == 180 &&
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
}
