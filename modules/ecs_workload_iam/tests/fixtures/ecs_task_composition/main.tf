# Test-only root: modules/ecs_task jobs consuming modules/ecs_workload_iam roles.
# IAM log-group ARNs follow the ecs_task naming contract instead of consuming
# module.ecs_task.log_groups, which would create a dependency cycle.

data "aws_partition" "current" {}

locals {
  name_prefix    = "unit-test-dev"
  account_id     = "123456789012"
  primary_region = "us-east-1"

  jobs = {
    archive = {
      repository = "archive"
      image      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/archive@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }

    report = {
      repository = "report"
      image      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/report@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  }

  approved_cluster_arn = "arn:aws:ecs:us-east-1:123456789012:cluster/unit-test-dev"
}

module "ecs_workload_iam" {
  source = "../../.."

  name_prefix    = local.name_prefix
  environment    = "dev"
  account_id     = local.account_id
  primary_region = local.primary_region

  workloads = {
    for job_name, job in local.jobs : job_name => {
      ecr_repository_arns = [
        "arn:${data.aws_partition.current.partition}:ecr:${local.primary_region}:${local.account_id}:repository/${job.repository}"
      ]

      log_group_arns = [
        "arn:${data.aws_partition.current.partition}:logs:${local.primary_region}:${local.account_id}:log-group:/aws/ecs/${local.name_prefix}/jobs/${job_name}"
      ]
    }
  }
}

module "ecs_task" {
  source = "../../../../ecs_task"

  name_prefix    = local.name_prefix
  environment    = "dev"
  primary_region = local.primary_region

  cloudwatch_retention_days = 14
  logs_cmk_arn              = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  tasks = {
    for job_name, job in local.jobs : job_name => {
      image              = job.image
      cpu                = 256
      memory             = 512
      execution_role_arn = module.ecs_workload_iam.execution_roles[job_name].arn
      task_role_arn      = module.ecs_workload_iam.task_roles[job_name].arn
    }
  }
}

# Synthetic launcher trust for test-only composition.
# Production caller identity and permission boundaries
# require separate M0 admission approval.
data "aws_iam_policy_document" "launcher_trust" {
  for_each = local.jobs

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.account_id}:role/unit-test-dev-${each.key}-caller"
      ]
    }
  }
}

resource "aws_iam_role" "launcher" {
  for_each = local.jobs

  name               = "${local.name_prefix}-${each.key}-launcher"
  assume_role_policy = data.aws_iam_policy_document.launcher_trust[each.key].json
}

data "aws_iam_policy_document" "job_launch" {
  for_each = local.jobs

  statement {
    sid     = "RunApprovedTaskRevision"
    effect  = "Allow"
    actions = ["ecs:RunTask"]

    resources = [
      module.ecs_task.task_definitions[each.key].arn
    ]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.approved_cluster_arn]
    }
  }

  statement {
    sid     = "PassOnlyApprovedJobRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]

    resources = [
      module.ecs_workload_iam.execution_roles[each.key].arn,
      module.ecs_workload_iam.task_roles[each.key].arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "job_launch" {
  for_each = local.jobs

  name   = "${local.name_prefix}-${each.key}-job-launch"
  role   = aws_iam_role.launcher[each.key].name
  policy = data.aws_iam_policy_document.job_launch[each.key].json
}

output "iam_log_group_arns" {
  value = {
    for job_name, job in local.jobs : job_name => toset([
      "arn:${data.aws_partition.current.partition}:logs:${local.primary_region}:${local.account_id}:log-group:/aws/ecs/${local.name_prefix}/jobs/${job_name}"
    ])
  }
}

output "job_log_groups" {
  value = module.ecs_task.log_groups
}

output "execution_policy_ids" {
  value = module.ecs_workload_iam.execution_policy_ids
}

output "task_role_policy_attachment_ids" {
  value = module.ecs_workload_iam.task_role_policy_attachment_ids
}

output "launcher_policy_roles" {
  value = {
    for job_name, policy in aws_iam_role_policy.job_launch :
    job_name => policy.role
  }
}

output "launcher_policy_boundaries" {
  description = "Test-only launcher IAM actions and conditions."

  value = {
    for job_name, policy in data.aws_iam_policy_document.job_launch :
    job_name => {
      for statement in policy.statement :
      statement.sid => {
        effect  = statement.effect
        actions = toset(statement.actions)

        conditions = {
          for condition in statement.condition :
          "${condition.test}|${condition.variable}" => toset(condition.values)
        }
      }
    }
  }
}