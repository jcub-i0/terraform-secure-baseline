
# M1-N5A: Verify the actual environment-root variable type
# preserves multi-container ECS attributes.
# Offline, plan-only; no AWS infrastructure operations.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

mock_provider "random" {
  override_during = plan
}

# N5A tests environment-root input conversion, not the
# entire baseline resource graph.
override_module {
  target = module.baseline
}

variables {
  cloud_name         = "unit-test"
  deployment_profile = "minimal"
  abuseipdb_api_key  = "dummy"

  bucket_admin_principals = [
    "arn:aws:iam::123456789012:role/test-admin"
  ]

  ecs_services = {
    api = {
      repository_name = "api"
      image_digest    = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      container_port  = 8080
      cpu             = 1024
      memory          = 2048

      task_volumes          = ["shared"]
      ephemeral_storage_gib = 40

      mount_points = [{
        source_volume  = "shared"
        container_path = "/app/data"
        read_only      = false
      }]

      depends_on = [{
        container_name = "scanner"
        condition      = "HEALTHY"
      }]

      start_timeout_seconds = 90
      stop_timeout_seconds  = 40

      sidecars = {
        scanner = {
          repository_name = "scanner"
          image_digest    = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          essential       = true

          cpu_units              = 128
          memory_limit_mib       = 256
          memory_reservation_mib = 128

          environment_variables = {
            MODE = "synthetic"
          }

          secrets_manager_secrets = {
            TOKEN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-AbCdEf"
          }

          ssm_parameters = {
            CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/scanner/config"
          }

          command     = ["--foreground"]
          entry_point = ["/bin/scanner"]

          port_mappings = [{
            container_port = 9000
            protocol       = "tcp"
          }]

          read_only_root_filesystem = true

          health_check = {
            command = ["CMD-SHELL", "exit 0"]
          }

          start_timeout_seconds = 30
          stop_timeout_seconds  = 15
          dependency_rank       = 0

          mount_points = [{
            source_volume  = "shared"
            container_path = "/mnt/shared"
            read_only      = true
          }]
        }
      }
    }

    # Existing single-container callers must retain defaults.
    legacy = {
      repository_name = "legacy"
      container_port  = 8081
      cpu             = 512
      memory          = 1024
    }
  }
}

run "preserves_m1_service_attributes" {
  command = plan

  assert {
    condition = (
      var.ecs_services.api.task_volumes == toset(["shared"]) &&
      var.ecs_services.api.ephemeral_storage_gib == 40 &&
      var.ecs_services.api.mount_points[0].source_volume == "shared" &&
      var.ecs_services.api.mount_points[0].container_path == "/app/data" &&
      var.ecs_services.api.mount_points[0].read_only == false
    )

    error_message = "Environment root discarded ECS task storage attributes."
  }

  assert {
    condition = (
      length(var.ecs_services.api.depends_on) == 1 &&
      var.ecs_services.api.depends_on[0].container_name == "scanner" &&
      var.ecs_services.api.depends_on[0].condition == "HEALTHY" &&
      var.ecs_services.api.start_timeout_seconds == 90 &&
      var.ecs_services.api.stop_timeout_seconds == 40
    )

    error_message = "Environment root discarded container dependencies or timeouts."
  }
}

run "preserves_nested_sidecar_attributes" {
  command = plan

  assert {
    condition = (
      length(var.ecs_services.api.sidecars) == 1 &&
      var.ecs_services.api.sidecars.scanner.repository_name == "scanner" &&
      var.ecs_services.api.sidecars.scanner.image_digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" &&
      var.ecs_services.api.sidecars.scanner.essential == true &&
      var.ecs_services.api.sidecars.scanner.cpu_units == 128 &&
      var.ecs_services.api.sidecars.scanner.memory_limit_mib == 256 &&
      var.ecs_services.api.sidecars.scanner.memory_reservation_mib == 128
    )

    error_message = "Environment root discarded sidecar identity or resource settings."
  }

  assert {
    condition = (
      var.ecs_services.api.sidecars.scanner.environment_variables["MODE"] == "synthetic" &&
      var.ecs_services.api.sidecars.scanner.secrets_manager_secrets["TOKEN"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-AbCdEf" &&
      var.ecs_services.api.sidecars.scanner.ssm_parameters["CONFIG"] == "arn:aws:ssm:us-east-1:123456789012:parameter/scanner/config" &&
      var.ecs_services.api.sidecars.scanner.command[0] == "--foreground" &&
      var.ecs_services.api.sidecars.scanner.entry_point[0] == "/bin/scanner" &&
      var.ecs_services.api.sidecars.scanner.port_mappings[0].container_port == 9000 &&
      var.ecs_services.api.sidecars.scanner.port_mappings[0].protocol == "tcp"
    )

    error_message = "Environment root discarded sidecar runtime or secret settings."
  }

  assert {
    condition = (
      var.ecs_services.api.sidecars.scanner.read_only_root_filesystem == true &&
      var.ecs_services.api.sidecars.scanner.health_check.command[0] == "CMD-SHELL" &&
      var.ecs_services.api.sidecars.scanner.health_check.interval == 30 &&
      var.ecs_services.api.sidecars.scanner.start_timeout_seconds == 30 &&
      var.ecs_services.api.sidecars.scanner.stop_timeout_seconds == 15 &&
      var.ecs_services.api.sidecars.scanner.dependency_rank == 0 &&
      length(var.ecs_services.api.sidecars.scanner.depends_on) == 0 &&
      var.ecs_services.api.sidecars.scanner.mount_points[0].read_only == true
    )

    error_message = "Environment root discarded sidecar health, dependency, or filesystem settings."
  }
}

run "preserves_legacy_defaults" {
  command = plan

  assert {
    condition = (
      length(var.ecs_services.legacy.sidecars) == 0 &&
      length(var.ecs_services.legacy.task_volumes) == 0 &&
      length(var.ecs_services.legacy.mount_points) == 0 &&
      length(var.ecs_services.legacy.depends_on) == 0 &&
      var.ecs_services.legacy.ephemeral_storage_gib == null &&
      var.ecs_services.legacy.start_timeout_seconds == null &&
      var.ecs_services.legacy.stop_timeout_seconds == null
    )

    error_message = "Legacy ECS service defaults changed unexpectedly."
  }
}
