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

  execution_policy_ids = {
    api = "test-execution-policy"
  }

  security_policy_rule_ids = {
    api = ["sgr-0123456789abcdef0"]
  }
}

# 1. Reject mutable or incorrectly pinned sidecar images.

run "reject_invalid_sidecar_digest" {
  command = plan

  variables {
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
            image = "scanner:latest"
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

# 2. Reject dependencies on nonexistent sidecars.

run "reject_missing_dependency" {
  command = plan

  variables {
    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        depends_on = [
          {
            container_name = "nonexistent"
            condition      = "START"
          }
        ]
      }
    }
  }

  expect_failures = [var.services]
}

# 3. HEALTHY must reference a container with a health check.

run "reject_healthy_without_health_check" {
  command = plan

  variables {
    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        depends_on = [
          {
            container_name = "scanner"
            condition      = "HEALTHY"
          }
        ]

        sidecars = {
          scanner = {
            image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

# 4. COMPLETE cannot target an essential container.

run "reject_complete_on_essential_container" {
  command = plan

  variables {
    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        depends_on = [
          {
            container_name = "scanner"
            condition      = "COMPLETE"
          }
        ]

        sidecars = {
          scanner = {
            image     = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            essential = true
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

# 5. Reject cyclic sidecar dependencies.

run "reject_cyclic_dependencies" {
  command = plan

  variables {
    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        sidecars = {
          a = {
            image           = "a@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            dependency_rank = 1

            depends_on = [
              {
                container_name = "b"
                condition      = "START"
              }
            ]
          }

          b = {
            image           = "b@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            dependency_rank = 0

            depends_on = [
              {
                container_name = "a"
                condition      = "START"
              }
            ]
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

# 6. Reject mount points referencing undeclared volumes.

run "reject_undeclared_volume" {
  command = plan

  variables {
    services = {
      api = {
        image          = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        container_port = 8080
        cpu            = 512
        memory         = 1024

        execution_role_arn = "arn:aws:iam::123456789012:role/test-execution"
        task_role_arn      = "arn:aws:iam::123456789012:role/test-task"

        task_volumes = ["shared-data"]

        mount_points = [
          {
            source_volume  = "missing-volume"
            container_path = "/app/data"
          }
        ]
      }
    }
  }

  expect_failures = [var.services]
}
