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

  value = merge(
    {
      for service_name, service in aws_ecs_service.services :
      service_name => {
        arn              = service.arn
        name             = service.name
        platform_version = service.platform_version
      }
    },
    {
      for service_name, service in aws_ecs_service.autoscaled_services :
      service_name => {
        arn              = service.arn
        name             = service.name
        platform_version = service.platform_version
      }
    },
  )
}

output "autoscaling_targets" {
  description = "Application Auto Scaling targets for autoscaled ECS services."

  value = {
    for service_name, target in aws_appautoscaling_target.ecs_services :
    service_name => {
      arn                = target.arn
      resource_id        = target.resource_id
      min_capacity       = target.min_capacity
      max_capacity       = target.max_capacity
      scalable_dimension = target.scalable_dimension
      service_namespace  = target.service_namespace
    }
  }
}

output "autoscaling_cpu_policies" {
  description = "CPU target-tracking scaling policies keyed by ECS service name."

  value = {
    for service_name, policy in aws_appautoscaling_policy.ecs_cpu_target_tracking :
    service_name => {
      arn                = policy.arn
      name               = policy.name
      policy_type        = policy.policy_type
      resource_id        = policy.resource_id
      scalable_dimension = policy.scalable_dimension
      service_namespace  = policy.service_namespace
    }
  }
}

output "autoscaling_memory_policies" {
  description = "Memory target-tracking scaling policies keyed by ECS service name."

  value = {
    for service_name, policy in aws_appautoscaling_policy.ecs_memory_target_tracking :
    service_name => {
      arn                = policy.arn
      name               = policy.name
      policy_type        = policy.policy_type
      resource_id        = policy.resource_id
      scalable_dimension = policy.scalable_dimension
      service_namespace  = policy.service_namespace
    }
  }
}