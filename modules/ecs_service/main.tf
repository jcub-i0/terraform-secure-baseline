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

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = each.value.image
      essential = true

      portMappings = [
        {
          containerPort = each.value.container_port
          hostPort      = each.value.container_port
          protocol      = "tcp"
        }
      ]

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
          awslogs-group         = aws_cloudwatch_log_group.service_logs[each.key].name
          awslogs-region        = var.primary_region
          awslogs-stream-prefix = "ecs"

          mode = "non-blocking"
        }
      }
    }
  ])

  tags = {
    Name        = "${var.name_prefix}-${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_cloudwatch_log_group" "service_logs" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "/ecs/${var.name_prefix}/${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}

## ECS task execution IAM policy IDs that must exist before ECS services launch
resource "terraform_data" "ecs_execution_policy_ready" {
  input = var.execution_policy_ids
}

## ECS Security Group rule IDs that must exist before ECS services launch
resource "terraform_data" "ecs_security_policy_ready" {
  input = var.security_policy_rule_ids
}

resource "aws_ecs_service" "services" {
  for_each = var.services

  name            = "${var.name_prefix}-${each.key}"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.task_definitions[each.key].arn
  desired_count   = each.value.desired_count

  launch_type      = "FARGATE"
  platform_version = var.platform_version

  force_delete = true # CHANGE THIS IN PROD

  network_configuration {
    subnets          = var.compute_private_subnet_ids
    security_groups  = [aws_security_group.task_security_groups[each.key].id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  dynamic "load_balancer" {
    for_each = each.value.target_group_arn != null ? [each.value.target_group_arn] : []

    content {
      target_group_arn = load_balancer.value
      container_name   = each.key
      container_port   = each.value.container_port
    }
  }

  depends_on = [
    terraform_data.ecs_execution_policy_ready,
    terraform_data.ecs_security_policy_ready,
  ]

  tags = {
    Name        = "${var.name_prefix}-${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}