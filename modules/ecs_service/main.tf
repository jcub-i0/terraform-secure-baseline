resource "aws_security_group" "task_security_groups" {
  for_each = var.services

  name        = "${var.name_prefix}-${each.key}-ECS-Task-SG"
  description = "Security Group for ECS service ${each.key}"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.name_prefix}-${each.key}-ECS-Task-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_ecs_task_definition" "task_definitions" {
  for_each = var.services

  family                   = "${var.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = each.value.cpu
  memory = each.value.memory

  execution_role_arn = each.value.execution_role_arn
  task_role_arn      = each.value.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = each.value.cpu_architecture
  }

  container_definitions = []
}

resource "aws_cloudwatch_log_group" "service_logs" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}-${each.key}"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "/ecs/${var.name_prefix}/${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}