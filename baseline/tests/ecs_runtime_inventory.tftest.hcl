mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = [
        "us-east-1a",
        "us-east-1b",
        "us-east-1c"
      ]
    }
  }

  mock_ephemeral "aws_secretsmanager_random_password" {
    defaults = {
      random_password = "TestOnlyMockPassword123!"
    }
  }

  # Test-only policy JSON for unrelated baseline resources.
  # Actual IAM policy generation is tested separately in modules/iam.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"AWS\":\"arn:aws:iam::123456789012:root\"},\"Resource\":\"*\"}]}"
    }
  }
}

# Supply deterministic ECR outputs without testing ECR itself.
override_module {
  target = module.ecr

  outputs = {
    repositories = {
      for name in ["api", "scanner", "worker"] :
      name => {
        arn            = "arn:aws:ecr:us-east-1:123456789012:repository/unit-test-dev-${name}"
        repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/unit-test-dev-${name}"
      }
    }
  }
}

variables {
  environment                        = "dev"
  primary_region                     = "us-east-1"
  account_id                         = "123456789012"
  random_id                          = "1234abcd"
  break_glass_trusted_principal_arns = ["arn:aws:iam::123456789012:role/test-admin"]
  cloud_name                         = "unit-test"
  deployment_profile                 = "minimal"
  abuseipdb_api_key                  = "dummy"

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
      repository_name = "worker"
      image_digest    = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      container_port  = 8081
      cpu             = 512
      memory          = 1024
    }
  }
}

run "runtime_inventory" {
  command = plan

  plan_options {
    target = [module.ecs_service]
  }

  assert {
    condition = (
      keys(output.ecs_service_configuration.api.containers) == ["api", "scanner"] &&
      keys(output.ecs_service_configuration.legacy.containers) == ["legacy"] &&
      output.ecs_service_configuration.api.containers.api.name == "api" &&
      output.ecs_service_configuration.api.containers.api.essential &&
      output.ecs_service_configuration.api.containers.scanner.image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/unit-test-dev-scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" &&
      output.ecs_service_configuration.api.containers.api.image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/unit-test-dev-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    error_message = "Expected named primary and sidecar inventory with exact managed-ECR images."
  }

  assert {
    condition = (
      output.ecs_service_configuration.api.task_cpu == "1024" &&
      output.ecs_service_configuration.api.task_memory == "2048" &&
      output.ecs_service_configuration.api.cpu_architecture == "X86_64" &&
      output.ecs_service_configuration.api.task_volumes == [{ name = "shared" }] &&
      output.ecs_service_configuration.api.ephemeral_storage_gib == 40 &&
      output.ecs_service_configuration.legacy.task_volumes == [] &&
      output.ecs_service_configuration.legacy.ephemeral_storage_gib == null
    )
    error_message = "Task storage/resources must be explicit, including legacy defaults."
  }

  assert {
    condition = (
      output.ecs_service_configuration.api.containers.api.dependsOn == [{ containerName = "scanner", condition = "HEALTHY" }] &&
      output.ecs_service_configuration.api.containers.api.startTimeout == 90 &&
      output.ecs_service_configuration.api.containers.api.stopTimeout == 40 &&
      jsonencode(output.ecs_service_configuration.api.containers.scanner.healthCheck) == jsonencode({
        command = ["CMD-SHELL", "exit 0"], interval = 30, timeout = 5, retries = 3, startPeriod = 0
      }) &&
      output.ecs_service_configuration.api.containers.scanner.startTimeout == 30 &&
      output.ecs_service_configuration.api.containers.scanner.stopTimeout == 15 &&
      output.ecs_service_configuration.api.containers.scanner.essential &&
      output.ecs_service_configuration.api.containers.scanner.cpu == 128 &&
      output.ecs_service_configuration.api.containers.scanner.memory == 256 &&
      output.ecs_service_configuration.api.containers.scanner.memoryReservation == 128 &&
      output.ecs_service_configuration.api.containers.scanner.readonlyRootFilesystem &&
      output.ecs_service_configuration.api.containers.scanner.command == tolist(["--foreground"]) &&
      output.ecs_service_configuration.api.containers.scanner.entryPoint == tolist(["/bin/scanner"])
    )
    error_message = "Container behavior, dependencies, health and resource settings must survive output conversion."
  }

  assert {
    condition = (
      output.ecs_service_configuration.api.containers.scanner.mountPoints == [{ sourceVolume = "shared", containerPath = "/mnt/shared", readOnly = true }] &&
      output.ecs_service_configuration.api.containers.api.mountPoints == [{ sourceVolume = "shared", containerPath = "/app/data", readOnly = false }] &&
      output.ecs_service_configuration.api.containers.scanner.portMappings == [{ containerPort = 9000, hostPort = 9000, protocol = "tcp" }] &&
      output.ecs_service_configuration.api.containers.api.portMappings == [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }] &&
      output.ecs_service_configuration.api.containers.scanner.logConfiguration == output.ecs_service_configuration.api.containers.api.logConfiguration &&
      output.ecs_service_configuration.api.containers.scanner.logConfiguration.options.mode == "non-blocking" &&
      output.ecs_service_configuration.api.containers.scanner.logConfiguration.options["awslogs-region"] == "us-east-1"
    )
    error_message = "Mounts, ports and shared secure logging must be included."
  }

  assert {
    condition = (
      output.ecs_service_configuration.api.containers.scanner.environment_hashes == [{ name = "MODE", value_sha256 = sha256("synthetic") }] &&
      !strcontains(jsonencode(output.ecs_service_configuration), "synthetic") &&
      output.ecs_service_configuration.api.containers.scanner.secrets == [
        { name = "CONFIG", valueFrom = "arn:aws:ssm:us-east-1:123456789012:parameter/scanner/config" },
        { name = "TOKEN", valueFrom = "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-AbCdEf" }
      ] &&
      output.ecs_service_configuration.legacy.containers.legacy.healthCheck == null &&
      output.ecs_service_configuration.legacy.containers.legacy.startTimeout == null &&
      output.ecs_service_configuration.legacy.containers.legacy.memory == null
    )
    error_message = "Only hashed environment values and secret references may be exposed; absent settings must remain absent."
  }
}

run "empty_runtime_inventory" {
  command = plan
  variables {
    ecs_services = {}
  }
  plan_options {
    target = [module.ecs_service]
  }
  assert {
    condition     = output.ecs_service_configuration == {}
    error_message = "No deployable services must produce an empty runtime contract."
  }
}
