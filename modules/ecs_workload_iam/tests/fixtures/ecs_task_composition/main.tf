# Test-only root: modules/ecs_task jobs consuming modules/ecs_workload_iam roles.
# IAM log-group ARNs follow the ecs_task naming contract instead of consuming
# module.ecs_task.log_groups, which would create a dependency cycle.

data "aws_partition" "current" {}

locals {
  name_prefix    = "unit-test-dev"
  account_id     = "123456789012"
  primary_region = "us-east-1"

  jobs = {
    report = {
      repository = "report"
      image      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/report@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  }
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
