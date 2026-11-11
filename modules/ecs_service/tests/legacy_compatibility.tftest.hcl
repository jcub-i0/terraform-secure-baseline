
mock_provider "aws" {}

variables {
  name_prefix    = "unit-test"
  environment    = "dev"
  primary_region = "us-east-1"

  vpc_id       = "vpc-0123456789abcdef0"
  cluster_name = "unit-test-cluster"
  cluster_arn  = "arn:aws:ecs:us-east-1:123456789012:cluster/unit-test-cluster"

  compute_private_subnet_ids = [
    "subnet-0123456789abcdef0"
  ]

  cloudwatch_retention_days = 14

  logs_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  force_delete = false
}

run "empty_services" {
  command = plan

  variables {
    services = {}
  }

  assert {
    condition = (
      length(aws_ecs_task_definition.task_definitions) == 0 &&
      length(aws_ecs_service.services) == 0 &&
      length(aws_ecs_service.autoscaled_services) == 0 &&
      length(aws_security_group.task_security_groups) == 0
    )

    error_message = "Empty services must not create ECS task definitions, services, or task security groups."
  }
}

run "legacy_fixed_service" {
  command = plan

  variables {
    services = {
      api = {
        image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"
      }
    }

    execution_policy_ids = {
      api = "test-execution-policy"
    }

    security_policy_rule_ids = {
      api = ["sgr-0123456789abcdef0"]
    }
  }

  assert {
    condition = (
      length(aws_ecs_task_definition.task_definitions) == 1 &&
      length(aws_ecs_service.services) == 1 &&
      length(aws_ecs_service.autoscaled_services) == 0
    )

    error_message = "Legacy fixed-count service resource selection changed."
  }

  assert {
    condition = aws_ecs_task_definition.task_definitions["api"].container_definitions == jsonencode([
      {
        name      = "api"
        image     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        essential = true

        portMappings = [
          {
            containerPort = 8080
            hostPort      = 8080
            protocol      = "tcp"
          }
        ]

        environment = []
        secrets     = []

        logConfiguration = {
          logDriver = "awslogs"

          options = {
            awslogs-group         = "/aws/ecs/unit-test/api"
            awslogs-region        = "us-east-1"
            awslogs-stream-prefix = "ecs"
            mode                  = "non-blocking"
          }
        }
      }
    ])

    error_message = "Legacy single-container JSON differs from the pre-M1 contract."
  }
}

run "legacy_autoscaled_service" {
  command = plan

  variables {
    services = {
      api = {
        image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        container_port = 8080
        cpu            = 512
        memory         = 1024
        desired_count  = 2

        scaling = {
          min_capacity       = 1
          max_capacity       = 4
          cpu_target_percent = 50
        }

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"
      }
    }

    execution_policy_ids = {
      api = "test-execution-policy"
    }

    security_policy_rule_ids = {
      api = ["sgr-0123456789abcdef0"]
    }
  }

  assert {
    condition = (
      length(aws_ecs_service.services) == 0 &&
      length(aws_ecs_service.autoscaled_services) == 1 &&
      length(aws_ecs_task_definition.task_definitions) == 1 &&
      length(aws_appautoscaling_target.ecs_services) == 1
    )

    error_message = "Legacy autoscaled service resource selection changed."
  }

  assert {
    condition = (
      aws_ecs_service.autoscaled_services["api"].desired_count == 2 &&
      aws_ecs_service.autoscaled_services["api"].name == "unit-test-api"
    )

    error_message = "Autoscaled service bootstrap configuration changed."
  }

  assert {
    condition = (
      aws_appautoscaling_target.ecs_services["api"].min_capacity == 1 &&
      aws_appautoscaling_target.ecs_services["api"].max_capacity == 4 &&
      aws_appautoscaling_target.ecs_services["api"].resource_id == "service/unit-test-cluster/unit-test-api"
    )

    error_message = "ECS autoscaling target configuration changed."
  }

  assert {
    condition = (
      length(aws_appautoscaling_policy.ecs_cpu_target_tracking) == 1 &&
      length(aws_appautoscaling_policy.ecs_memory_target_tracking) == 0 &&
      length(aws_appautoscaling_policy.ecs_alb_request_target_tracking) == 0
    )

    error_message = "Unexpected autoscaling policies were created."
  }

  assert {
    condition = (
      length(jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)) == 1 &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].name == "api"
    )

    error_message = "Legacy autoscaled task must contain exactly the original primary container."
  }
}
