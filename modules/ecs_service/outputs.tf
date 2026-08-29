output "task_security_group_ids" {
  description = "ECS task Security Group IDs keyed by service name"

  value = {
    for service_name, security_group in aws_security_group.task_security_groups :
    service_name => security_group.id
  }
}

output "log_groups" {
  description = "ECS CloudWatch log-group metadata keyed by service name"

  value = {
    for service_name, log_group in aws_cloudwatch_log_group.service_logs :
    service_name => {
      arn  = log_group.arn
      name = log_group.name
    }
  }
}

output "task_definition_arns" {
  description = "ECS task definition ARNs keyed by service name"

  value = {
    for service_name, task_definition in aws_ecs_task_definition.task_definitions :
    service_name => task_definition.arn
  }
}

output "services" {
  description = "ECS service metadata keyed by service name"

  value = {
    for service_name, service in aws_ecs_service.services :
    service_name => {
      arn  = service.arn
      name = service.name
      platform_version = service.platform_version
    }
  }
}