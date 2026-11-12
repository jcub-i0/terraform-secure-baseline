
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

  services = {
    api = {
      image              = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      container_port     = 8080
      cpu                = 512
      memory             = 1024
      execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
      task_role_arn      = "arn:aws:iam::123456789012:role/test-task"
      task_volumes       = ["shared"]
      sidecars = {
        scanner = { image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
      }
    }
  }
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
              },
              {
                container_name = "setup_complete"
                condition      = "COMPLETE"
              },
              {
                container_name = "setup_success"
                condition      = "SUCCESS"
              }
            ]

            health_check = {
              command = [
                "CMD-SHELL",
                "test -f /scanner/shared/ready"
              ]
              interval     = 17
              timeout      = 7
              retries      = 4
              start_period = 23
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

          setup_complete = {
            image           = "busybox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            essential       = false
            dependency_rank = 0
            command         = ["sh", "-c", "exit 0"]
          }

          setup_success = {
            image           = "busybox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            essential       = false
            dependency_rank = 0
            command         = ["sh", "-c", "exit 0"]
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
    ] == ["api", "scanner", "setup_complete", "setup_success", "telemetry"]

    error_message = "Expected the primary container followed by deterministically sorted sidecars."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].dependsOn[0].containerName == "scanner" &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].dependsOn[0].condition == "HEALTHY" &&
      { for dependency in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].dependsOn :
        dependency.containerName => dependency.condition
      } == { telemetry = "START", setup_complete = "COMPLETE", setup_success = "SUCCESS" } &&
      alltrue([
        for container in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions) :
        container.essential == false if contains(["setup_complete", "setup_success"], container.name)
      ])
    )

    error_message = "Render HEALTHY/START and COMPLETE/SUCCESS dependencies on their nonessential initialization prerequisites."
  }

  assert {
    condition = jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].healthCheck == {
      command     = ["CMD-SHELL", "test -f /scanner/shared/ready"]
      interval    = 17
      timeout     = 7
      retries     = 4
      startPeriod = 23
    }
    error_message = "Explicit sidecar health-check timings must survive task-definition rendering."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].essential == true &&
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[4].essential == false &&

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
      jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[4].mountPoints[0].readOnly == true
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

run "n5ca_accept_0_sidecars_per_service" {
  command = plan
  variables {
    services = {
      for name in ["api", "worker"] : name => merge(var.services.api, {
        sidecars = { for i in range(0) : "helper_${i}" => { image = var.services.api.image } }
      })
    }
    execution_policy_ids     = { for name in ["api", "worker"] : name => "test-execution-policy" }
    security_policy_rule_ids = { for name in ["api", "worker"] : name => ["sgr-0123456789abcdef0"] }
  }
  assert {
    condition = alltrue([
      for task in values(aws_ecs_task_definition.task_definitions) :
      length(jsondecode(task.container_definitions)) == 1
    ])
    error_message = "Each task must contain exactly its primary and declared sidecars; runtime-injected agents are not counted."
  }
}

run "n5ca_accept_9_sidecars_per_service" {
  command = plan
  variables {
    services = {
      for name in ["api", "worker"] : name => merge(var.services.api, {
        sidecars = { for i in range(9) : "helper_${i}" => { image = var.services.api.image } }
      })
    }
    execution_policy_ids     = { for name in ["api", "worker"] : name => "test-execution-policy" }
    security_policy_rule_ids = { for name in ["api", "worker"] : name => ["sgr-0123456789abcdef0"] }
  }
  assert {
    condition = alltrue([
      for task in values(aws_ecs_task_definition.task_definitions) :
      length(jsondecode(task.container_definitions)) == 10
    ])
    error_message = "Each task must contain exactly its primary and declared sidecars; runtime-injected agents are not counted."
  }
}

run "n5ca_accept_direct_image_reference_forms" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        image = "nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        sidecars = {
          for i, repository in [
            "docker.io/library/busybox",
            "registry.example.com:5000/team/nested/image",
            "localhost:5000/team/image:Release_1.2",
            "public.ecr.aws/example/image",
            "123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn/team/image",
            "123456789012.dkr.ecr.us-gov-west-1.amazonaws.com/team/image"
          ] : "helper_${i}" => { image = "${repository}@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
        }
      })
    }
    execution_policy_ids     = { api = "test-execution-policy" }
    security_policy_rule_ids = { api = ["sgr-0123456789abcdef0"] }
  }
  assert {
    condition = toset([
      for container in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions) : container.image
    ]) == toset(concat([var.services.api.image], [for sidecar in values(var.services.api.sidecars) : sidecar.image]))
    error_message = "Valid direct-module image references must be preserved exactly."
  }
}

run "n5ca_accept_canonical_shared_mounts" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [
          { source_volume = "shared", container_path = "/app/.config" },
          { source_volume = "shared", container_path = "/app/data..v2" }
        ]
        sidecars = {
          scanner = merge(var.services.api.sidecars.scanner, {
            mount_points = [
              { source_volume = "shared", container_path = "/scanner/data", read_only = true },
              { source_volume = "shared", container_path = "/app/.config" }
            ]
          })
        }
      })
    }
    execution_policy_ids     = { api = "test-execution-policy" }
    security_policy_rule_ids = { api = ["sgr-0123456789abcdef0"] }
  }
  assert {
    condition = (
      length(aws_ecs_task_definition.task_definitions["api"].volume) == 1 &&
      alltrue([
        for container in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions) :
        length(container.mountPoints) == 2 && alltrue([for mount in container.mountPoints : mount.sourceVolume == "shared"])
      ])
    )
    error_message = "Canonical paths, including dotted names and shared destinations across containers, must remain valid."
  }
}

run "n5ca_accept_exact_ssm_names_paths_and_partitions" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        secrets = {
          NAME          = "App_Config.v2-1"
          PATH          = "/app/config.v2-1"
          RELATIVE_PATH = "app/config"
          COMMERCIAL    = "arn:aws:ssm:us-east-1:123456789012:parameter/app/Config.v2-1"
          GOV           = "arn:aws-us-gov:ssm:us-gov-west-1:123456789012:parameter/app/config"
          CHINA         = "arn:aws-cn:ssm:cn-north-1:123456789012:parameter/app/config"
        }
        sidecars = {
          scanner = merge(var.services.api.sidecars.scanner, {
            secrets = {
              NAME          = "App_Config.v2-1"
              PATH          = "/app/config.v2-1"
              RELATIVE_PATH = "app/config"
              COMMERCIAL    = "arn:aws:ssm:us-east-1:123456789012:parameter/app/Config.v2-1"
              GOV           = "arn:aws-us-gov:ssm:us-gov-west-1:123456789012:parameter/app/config"
              CHINA         = "arn:aws-cn:ssm:cn-north-1:123456789012:parameter/app/config"
            }
          })
        }
      })
    }
    execution_policy_ids     = { api = "test-execution-policy" }
    security_policy_rule_ids = { api = ["sgr-0123456789abcdef0"] }
  }
  assert {
    condition = alltrue([
      for container in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions) :
      toset([for secret in container.secrets : secret.valueFrom]) == toset(values(var.services.api.secrets))
    ])
    error_message = "Exact SSM names, paths, and partition ARNs must pass through both container types unchanged."
  }
}
