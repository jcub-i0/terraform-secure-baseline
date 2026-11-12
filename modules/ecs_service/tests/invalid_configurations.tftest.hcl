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

run "reject_primary_container_name_collision" {
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
          api = {
            image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

run "reject_duplicate_container_port" {
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
            image = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

            port_mappings = [
              {
                container_port = 8080
              }
            ]
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_digest_suffix" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:tag"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_root" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_parent_component" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data/../cache" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_duplicate_destination" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data" }, { source_volume = "shared", container_path = "/data" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "reject_sidecar_environment_secret_collision" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = {
          scanner = merge(var.services.api.sidecars.scanner, {
            environment_variables = { TOKEN = "must-not-shadow-a-secret" }
            secrets               = { TOKEN = "arn:aws:ssm:us-east-1:123456789012:parameter/token" }
          })
        }
      })
    }
  }

  expect_failures = [var.services]
}
