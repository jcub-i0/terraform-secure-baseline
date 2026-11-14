resource "aws_cloudwatch_log_group" "job_logs" {
  for_each = var.tasks

  name              = "/aws/ecs${var.name_prefix}/jobs/${each.key}"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "/aws/ecs/${var.name_prefix}/jobs/${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}


resource "aws_ecs_task_definition" "jobs" {
  for_each = var.tasks

  family                   = "${var.name_prefix}-job-${each.key}"
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

  container_definitions = jsonencode([
    merge(
      {
        name      = each.key
        image     = each.value.image
        essential = true

        environment = [
          for name, value in each.value.environment_variables : {
            name  = name
            value = value
          }
        ]

        secrets = [
          for name, value_from in each.value.secrets : {
            name      = name
            valueFrom = value_from
          }
        ]

        logConfiguration = {
          logDriver = "awslogs"

          options = {
            awslogs-group         = aws_cloudwatch_log_group.job_logs[each.key].name
            awslogs-region        = var.primary_region
            awslogs-stream-prefix = "ecs"
          }
        }
      },

      each.value.command == null ? {} : {
        command = each.value.command
      }
    )
  ])

  tags = {
    Name        = "${var.name_prefix}-job-${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}
