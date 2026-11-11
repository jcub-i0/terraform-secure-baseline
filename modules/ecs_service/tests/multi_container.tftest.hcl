
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

run "multi_container_task" {
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

        target_group_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test-api/0123456789abcdef"

        task_volumes          = ["shared-data"]
        ephemeral_storage_gib = 50

        mount_points = [
          {
            source_volume  = "shared-data"
            container_path = "/app/shared"
          }
        ]

        depends_on = [
          {
            container_name = "scanner"
            condition      = "HEALTHY"
          }
        ]

        sidecars = {
          scanner = {
            image     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/scanner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            essential = true

            cpu_units              = 64
            memory_limit_mib       = 256
            memory_reservation_mib = 128

            dependency_rank = 1

            depends_on = [
              {
                container_name = "telemetry"
                condition      = "START"
              }
            ]

            health_check = {
              command = [
                "CMD-SHELL",
                "test -f /scanner/shared/ready"
              ]
            }

            port_mappings = [
              {
                container_port = 3310
              }
            ]

            start_timeout_seconds     = 90
            stop_timeout_seconds      = 30
            read_only_root_filesystem = true

            mount_points = [
              {
                source_volume  = "shared-data"
                container_path = "/scanner/shared"
                read_only      = false
              }
            ]
          }

          telemetry = {
            image     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/telemetry@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            essential = false

            cpu_units              = 32
            memory_limit_mib       = 128
            memory_reservation_mib = 64

            environment_variables = {
              MODE = "audit"
            }

            secrets = {
              TELEMETRY_CONFIG_PARAMETER = "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
            }

            mount_points = [
              {
                source_volume  = "shared-data"
                container_path = "/telemetry/shared"
                read_only      = true
              }
            ]
          }
        }
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
      length(aws_ecs_service.autoscaled_services) == 0 &&
      length(aws_security_group.task_security_groups) == 1
    )

    error_message = "Multi-container configuration must retain one task definition, one fixed ECS service, and one task security group."
  }

  assert {
    condition = [
      for container in jsondecode(
        aws_ecs_task_definition.task_definitions["api"].container_definitions
      ) : container.name
    ] == ["api", "scanner", "telemetry"]

    error_message = "Expected the primary container followed by deterministically sorted sidecars."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].dependsOn[0].containerName == "scanner" &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].dependsOn[0].condition == "HEALTHY" &&

      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].dependsOn[0].containerName == "telemetry" &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].dependsOn[0].condition == "START"
    )

    error_message = "Primary and sidecar startup dependencies were not serialized correctly."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].essential == true &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[2].essential == false &&

      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].cpu == 64 &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].memory == 256 &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].memoryReservation == 128 &&

      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].readonlyRootFilesystem == true
    )

    error_message = "Sidecar resource limits, essential flags, or read-only filesystem were not serialized correctly."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].mountPoints[0].sourceVolume == "shared-data" &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].mountPoints[0].containerPath == "/scanner/shared" &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[2].mountPoints[0].readOnly == true
    )

    error_message = "Shared-volume mount points were not serialized correctly."
  }

  assert {
    condition = (
      length(aws_ecs_task_definition.task_definitions["api"].volume) == 1 &&
      alltrue([
        for volume in aws_ecs_task_definition.task_definitions["api"].volume :
        volume.name == "shared-data"
      ]) &&
      alltrue([
        for storage in aws_ecs_task_definition.task_definitions["api"].ephemeral_storage :
        storage.size_in_gib == 50
      ])
    )

    error_message = "Task-scoped volume or ephemeral storage configuration is incorrect."
  }

  assert {
    condition = (
      length(aws_ecs_service.services["api"].load_balancer) == 1 &&
      alltrue([
        for lb in aws_ecs_service.services["api"].load_balancer :
        lb.container_name == "api" && lb.container_port == 8080
      ])
    )

    error_message = "The ALB must continue targeting the primary API container."
  }
}
