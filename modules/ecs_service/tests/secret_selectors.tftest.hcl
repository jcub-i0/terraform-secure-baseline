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
  logs_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  force_delete = false

  execution_policy_ids = {
    api = "test-execution-policy"
  }

  security_policy_rule_ids = {
    api = ["sgr-0123456789abcdef0"]
  }
}

run "accept_valid_selectors_on_1_4" {
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

        secrets = {
          JSON_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf:password::"
          STAGE    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf::AWSPREVIOUS:"
        }

        sidecars = {
          scanner = {
            image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

            secrets = {
              VERSION_ID = "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl:::version123"
              PARAMETER  = "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
            }
          }
        }
      }
    }
  }

  assert {
    condition = (
      contains(
        [for secret in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].secrets : secret.valueFrom],
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf:password::"
      ) &&
      contains(
        [for secret in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[0].secrets : secret.valueFrom],
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf::AWSPREVIOUS:"
      ) &&
      contains(
        [for secret in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].secrets : secret.valueFrom],
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl:::version123"
      ) &&
      contains(
        [for secret in jsondecode(aws_ecs_task_definition.task_definitions["api"].container_definitions)[1].secrets : secret.valueFrom],
        "arn:aws:ssm:us-east-1:123456789012:parameter/app/config"
      )
    )

    error_message = "Valid primary and sidecar secret selectors must be preserved without altering SSM references."
  }
}

run "reject_conflicting_primary_selectors" {
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

        secrets = {
          BAD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf:password:AWSPREVIOUS:version123"
        }
      }
    }
  }

  expect_failures = [var.services]
}

run "reject_conflicting_sidecar_selectors" {
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

        sidecars = {
          scanner = {
            image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

            secrets = {
              BAD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-GhIjKl::AWSPREVIOUS:version123"
            }
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

run "accept_full_secret_on_1_3" {
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

        secrets = {
          FULL           = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf"
          EXPLICIT_EMPTY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf:::"
        }
      }
    }
  }

  assert {
    condition = (
      length(jsondecode(
        aws_ecs_task_definition.task_definitions["api"].container_definitions
      )[0].secrets) == 2
    )

    error_message = "Fargate 1.3.0 must support full-secret references without selectors."
  }
}

run "reject_selected_secret_on_1_3" {
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

        secrets = {
          JSON_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf:password::"
        }
      }
    }
  }

  expect_failures = [var.platform_version]
}

run "reject_secret_injection_on_1_2" {
  command = plan

  variables {
    platform_version = "1.2.0"

    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        secrets = {
          FULL = "arn:aws:secretsmanager:us-east-1:123456789012:secret:app-AbCdEf"
        }
      }
    }
  }

  expect_failures = [var.platform_version]
}