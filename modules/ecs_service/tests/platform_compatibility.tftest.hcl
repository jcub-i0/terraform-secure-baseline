mock_provider "aws" {}

variables {
  name_prefix    = "unit-test"
  environment    = "dev"
  primary_region = "us-east-1"

  vpc_id       = "vpc-0123456789abcdef0"
  cluster_name = "unit-test-cluster"
  cluster_arn  = "arn:aws:ecs:us-east-1:123456789012:cluster/unit-test-cluster"

  compute_private_subnet_ids = ["subnet-0123456789abcdef0"]

  cloudwatch_retention_days = 14
  logs_cmk_arn              = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  force_delete = false

  execution_policy_ids = {
    api = "test-execution-policy"
  }

  security_policy_rule_ids = {
    api = ["sgr-0123456789abcdef0"]
  }

  services = {
    api = {
      image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      container_port = 8080
      cpu            = 512
      memory         = 1024

      execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
      task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

      sidecars = {
        scanner = {
          image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
      }

      depends_on = [
        {
          container_name = "scanner"
          condition      = "START"
        }
      ]
    }
  }
}

run "reject_dependencies_on_1_2" {
  command = plan

  variables {
    platform_version = "1.2.0"
  }

  expect_failures = [var.platform_version]
}

run "accept_dependencies_on_1_3" {
  command = plan

  variables {
    platform_version = "1.3.0"
  }

  assert {
    condition = (
      jsondecode(
        aws_ecs_task_definition.task_definitions["api"].container_definitions
      )[0].dependsOn[0].containerName == "scanner"
    )

    error_message = "Container dependencies must be supported on platform 1.3.0."
  }
}

run "reject_expanded_storage_on_1_3" {
  command = plan

  variables {
    platform_version = "1.3.0"

    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        ephemeral_storage_gib = 50
      }
    }
  }

  expect_failures = [var.platform_version]
}

run "accept_expanded_storage_on_1_4" {
  command = plan

  variables {
    platform_version = "1.4.0"

    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        ephemeral_storage_gib = 50
      }
    }
  }

  assert {
    condition = (
      aws_ecs_task_definition.task_definitions["api"].ephemeral_storage[0].size_in_gib == 50
    )

    error_message = "Platform 1.4.0 must support expanded ephemeral storage."
  }
}

run "accept_32_vcpu_61440_mib" {
  command = plan

  variables {
    platform_version = "1.4.0"
    services = {
      api = merge(var.services.api, { cpu = 32768, memory = 61440 })
    }
  }

  assert {
    condition = (
      aws_ecs_task_definition.task_definitions["api"].cpu == "32768" &&
      aws_ecs_task_definition.task_definitions["api"].memory == "61440"
    )
    error_message = "The supported 32-vCPU task size must be rendered exactly."
  }
}

run "accept_32_vcpu_122880_mib" {
  command = plan

  variables {
    platform_version = "1.4.0"
    services = {
      api = merge(var.services.api, { cpu = 32768, memory = 122880 })
    }
  }

  assert {
    condition = (
      aws_ecs_task_definition.task_definitions["api"].cpu == "32768" &&
      aws_ecs_task_definition.task_definitions["api"].memory == "122880"
    )
    error_message = "The supported 32-vCPU task size must be rendered exactly."
  }
}

run "accept_32_vcpu_249856_mib" {
  command = plan

  variables {
    platform_version = "1.4.0"
    services = {
      api = merge(var.services.api, { cpu = 32768, memory = 249856 })
    }
  }

  assert {
    condition = (
      aws_ecs_task_definition.task_definitions["api"].cpu == "32768" &&
      aws_ecs_task_definition.task_definitions["api"].memory == "249856"
    )
    error_message = "The supported 32-vCPU task size must be rendered exactly."
  }
}

run "reject_unsupported_32_vcpu_memory" {
  command = plan

  variables {
    platform_version = "1.4.0"
    services = {
      api = merge(var.services.api, { cpu = 32768, memory = 65536 })
    }
  }

  expect_failures = [var.services]
}
