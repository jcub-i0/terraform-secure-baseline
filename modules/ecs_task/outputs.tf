output "task_definitions" {
  description = "Standalone ECS task definitions keyed by job name"

  value = {
    for job_name, task in aws_ecs_task_definition.jobs :
    job_name => {
      arn                = task.arn
      family             = task.family
      revision           = task.revision
      execution_role_arn = task.execution_role_arn
      task_role_arn      = task.task_role_arn
    }
  }
}

output "log_groups" {
  description = "CloudWatch Logs metadata keyed by job name"

  value = {
    for job_name, log_group in aws_cloudwatch_log_group.job_logs :
    job_name => {
      arn  = log_group.arn
      name = log_group.name
    }
  }
}