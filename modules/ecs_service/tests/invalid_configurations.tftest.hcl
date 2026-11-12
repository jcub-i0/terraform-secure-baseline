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

run "reject_equal_rank_dependency" {
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
          bootstrap = {
            image           = "bootstrap@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            dependency_rank = 0
          }

          scanner = {
            image           = "scanner@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            dependency_rank = 0

            depends_on = [
              {
                container_name = "bootstrap"
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

run "reject_invalid_ephemeral_storage" {
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

        ephemeral_storage_gib = 20
      }
    }
  }

  expect_failures = [var.services]
}

run "reject_invalid_memory_reservation" {
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

            memory_limit_mib       = 128
            memory_reservation_mib = 128
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}

run "reject_invalid_start_timeout" {
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
            image                 = "scanner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            start_timeout_seconds = 121
          }
        }
      }
    }
  }

  expect_failures = [var.services]
}
# M1-N5C-A: each run mutates one otherwise-valid input. Expected failures
# identify variable validation; diagnostic audits also verify the exact rule.

run "n5ca_reject_10_sidecars" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { for i in range(10) : "helper_${i}" => { image = var.services.api.image } }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_11_sidecars" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { for i in range(11) : "helper_${i}" => { image = var.services.api.image } }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_missing_repository" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_leading_whitespace" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = " repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_embedded_whitespace" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo name@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_extra_at" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo@other@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_uppercase_digest" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_short_digest" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_long_digest" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
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

run "n5ca_reject_primary_image_trailing_newline" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
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

run "n5ca_reject_primary_mount_root_dot" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/." }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_root_parent" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/.." }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_parent_to_root" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data/.." }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_repeated_root_separator" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "//" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_empty_component" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data//cache" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_trailing_separator" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data/" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_dot_component" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data/./cache" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_parent_component" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data/../cache" }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_mount_relative" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "data" }]
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

run "n5ca_reject_primary_mount_equivalent_destinations" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        mount_points = [{ source_volume = "shared", container_path = "/data" }, { source_volume = "shared", container_path = "/data/." }]
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_star" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "*" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_question" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "?" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_path_star" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "/app/*" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_path_question" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "/app/config?" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_arn_star" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/*" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_arn_question" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/config?" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_region_wildcard" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "arn:aws:ssm:*:123456789012:parameter/app/config" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_unsupported_partition" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "arn:other:ssm:us-east-1:123456789012:parameter/app/config" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_wrong_resource" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:document/app" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_ssm_empty_parameter" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/" }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_missing_repository" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_leading_whitespace" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = " repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_embedded_whitespace" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo name@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_extra_at" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo@other@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_uppercase_digest" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_short_digest" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_long_digest" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_digest_suffix" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:tag" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_trailing_newline" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_root" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_root_dot" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/." }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_root_parent" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/.." }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_parent_to_root" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data/.." }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_repeated_root_separator" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "//" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_empty_component" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data//cache" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_trailing_separator" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data/" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_dot_component" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data/./cache" }] }) }
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

run "n5ca_reject_sidecar_mount_relative" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "data" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_duplicate_destination" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data" }, { source_volume = "shared", container_path = "/data" }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_mount_equivalent_destinations" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { mount_points = [{ source_volume = "shared", container_path = "/data" }, { source_volume = "shared", container_path = "/data/." }] }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_star" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "*" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_question" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "?" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_path_star" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "/app/*" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_path_question" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "/app/config?" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_arn_star" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/*" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_arn_question" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/app/config?" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_region_wildcard" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "arn:aws:ssm:*:123456789012:parameter/app/config" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_unsupported_partition" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "arn:other:ssm:us-east-1:123456789012:parameter/app/config" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_wrong_resource" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:document/app" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_ssm_empty_parameter" {
  command = plan

  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { secrets = { CONFIG = "arn:aws:ssm:us-east-1:123456789012:parameter/" } }) }
      })
    }
  }

  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_unicode_separator" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo\u00a0name@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }
  expect_failures = [var.services]
}

run "n5ca_reject_primary_image_unicode_next_line" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        image = "repo\u0085name@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })
    }
  }
  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_unicode_separator" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo\u00a0name@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }
  expect_failures = [var.services]
}

run "n5ca_reject_sidecar_image_unicode_next_line" {
  command = plan
  variables {
    services = {
      api = merge(var.services.api, {
        sidecars = { scanner = merge(var.services.api.sidecars.scanner, { image = "repo\u0085name@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) }
      })
    }
  }
  expect_failures = [var.services]
}
