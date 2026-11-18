output "execution_roles" {
  description = "ECS task execution roles keyed by workload name"

  value = {
    for service_name, role in aws_iam_role.ecs_task_execution_roles : service_name => {
      arn  = role.arn
      name = role.name
    }
  }
}

output "task_roles" {
  description = "ECS application task roles keyed by workload name"

  value = {
    for service_name, role in aws_iam_role.ecs_task_roles : service_name => {
      arn  = role.arn
      name = role.name
    }
  }
}

output "execution_policy_ids" {
  description = "ECS task execution inline-policy IDs keyed by workload name"

  value = {
    for service_name, policy in aws_iam_role_policy.ecs_task_execution_policies :
    service_name => policy.id
  }
}

output "task_role_policy_attachment_ids" {
  description = "Task-role managed-policy attachment IDs keyed by workload; only populated for opted-in workloads"

  value = {
    for service_name, service in var.workloads :
    service_name => toset([
      for key, attachment in aws_iam_role_policy_attachment.ecs_task_managed_policies :
      attachment.id
      if local.ecs_task_managed_policy_attachments[key].service_name == service_name
    ])
    if length(service.task_role_managed_policy_arns) > 0
  }
}
