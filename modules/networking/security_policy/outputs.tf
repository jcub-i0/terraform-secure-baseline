output "compute_sg_rule_ids" {
  description = "Security Group rule IDs that must exist before compute EC2 instances launch"

  value = {
    endpoints_ingress_from_compute = aws_security_group_rule.endpoints_ingress_from_compute.id
    compute_egress_to_endpoints    = aws_security_group_rule.compute_egress_to_endpoints.id
    compute_egress_to_db           = aws_security_group_rule.compute_egress_to_db.id

    compute_egress_to_internet_https = try(
      aws_security_group_rule.compute_egress_to_internet_https[0].id,
      null
    )
  }
}

output "ecs_sg_rule_ids" {
  description = "Security Group rule IDs that must exist before ECS tasks launch."

  value = {
    for service_name, service in var.ecs_security_policy_services : service_name => {
      endpoints_ingress = aws_security_group_rule.endpoints_ingress_from_ecs_tasks[service_name].id
      endpoints_egress  = aws_security_group_rule.ecs_tasks_egress_to_endpoints[service_name].id
      s3_egress         = aws_security_group_rule.ecs_tasks_egress_to_s3[service_name].id

      internet_https_egress = try(
        aws_security_group_rule.ecs_tasks_egress_to_internet_https[service_name].id,
        null
      )

      db_egress = try(
        aws_security_group_rule.ecs_tasks_egress_to_db[service_name].id,
        null
      )

      db_ingress = try(
        aws_security_group_rule.db_ingress_from_ecs_tasks[service_name].id,
        null
      )

      alb_ingress = try(
        aws_security_group_rule.ecs_tasks_ingress_from_alb[service_name].id,
        null
      )

      alb_egress = try(
        aws_security_group_rule.alb_egress_to_ecs_tasks[service_name].id,
        null
      )
    }
  }
}