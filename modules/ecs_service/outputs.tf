output "task_security_group_ids" {
  description = "ECS task Security Group IDs keyed by service name"

  value = {
    for service_name, security_group in aws_security_group.task_security_groups :
    service_name => security_group.id
  }
}