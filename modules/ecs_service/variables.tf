variable "name_prefix" {
  description = "Baseline naming prefix used to construct ECS service resources."
  type        = string
}

variable "environment" {
  description = "Workload environment identity used for tagging."
  type        = string
}

variable "primary_region" {
  description = "AWS Region in which ECS services and CloudWatch logs are created."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID used by ECS task security groups."
  type        = string
}
variable "cluster_arn" {
  description = "ARN of the ECS cluster that hosts the services."
  type        = string
}

variable "cluster_name" {
  description = "Name of the ECS cluster that hosts the services."
  type        = string
}

variable "compute_private_subnet_ids" {
  description = "Compute-private subnet IDs used by Fargate tasks."
  type        = set(string)
}

variable "cloudwatch_retention_days" {
  description = "CloudWatch Logs retention period for ECS service log groups."
  type        = number
}

variable "platform_version" {
  description = "AWS Fargate platform version. Defaults to the latest available platform."
  type        = string
  default     = "LATEST"

  validation {
    condition = (
      contains(["LATEST", "1.3.0", "1.4.0"], var.platform_version) ||
      alltrue([
        for service in values(var.services) :
        length(service.depends_on) == 0 &&
        service.start_timeout_seconds == null &&
        service.stop_timeout_seconds == null &&
        alltrue([
          for sidecar in values(service.sidecars) :
          length(sidecar.depends_on) == 0 &&
          sidecar.start_timeout_seconds == null &&
          sidecar.stop_timeout_seconds == null
        ])
      ])
    )

    error_message = "ECS container dependencies and start/stop timeouts require Fargate Linux platform 1.3.0 or later."
  }

  validation {
    condition = (
      contains(["LATEST", "1.4.0"], var.platform_version) ||
      alltrue([
        for service in values(var.services) :
        service.ephemeral_storage_gib == null &&
        service.cpu_architecture != "ARM64" &&
        service.cpu < 8192
      ])
    )

    error_message = "Expanded ephemeral storage, ARM64 workloads, and tasks with 8 or more vCPUs require Fargate Linux platform 1.4.0 or later."
  }
}

variable "services" {
  description = "ECS/Fargate services keyed by stable service name"

  type = map(object({
    image          = string
    container_port = number
    cpu            = number
    memory         = number
    desired_count  = optional(number, 1)

    scaling = optional(object({
      min_capacity               = number
      max_capacity               = number
      cpu_target_percent         = optional(number)
      memory_target_percent      = optional(number)
      alb_requests_per_target    = optional(number)
      scale_in_cooldown_seconds  = optional(number, 300)
      scale_out_cooldown_seconds = optional(number, 300)
    }), null)

    deployment = optional(object({
      minimum_healthy_percent           = optional(number, 100)
      maximum_percent                   = optional(number, 200)
      health_check_grace_period_seconds = optional(number, 0)
    }), {})

    health_check = optional(object({
      command      = list(string)
      interval     = optional(number, 30)
      timeout      = optional(number, 5)
      retries      = optional(number, 3)
      start_period = optional(number, 0)
    }), null)

    execution_role_arn = string
    task_role_arn      = string

    target_group_arn           = optional(string)
    alb_request_resource_label = optional(string)

    cpu_architecture = optional(string, "X86_64")

    environment_variables = optional(map(string), {})
    secrets               = optional(map(string), {})

    task_volumes = optional(set(string), [])

    ephemeral_storage_gib = optional(number)

    mount_points = optional(list(object({
      source_volume  = string
      container_path = string
      read_only      = optional(bool, false)
    })), [])

    start_timeout_seconds = optional(number)
    stop_timeout_seconds  = optional(number)

    depends_on = optional(list(object({
      container_name = string
      condition      = string
    })), [])

    sidecars = optional(map(object({
      image = string

      cpu_units              = optional(number)
      memory_limit_mib       = optional(number)
      memory_reservation_mib = optional(number)

      essential = optional(bool, true)

      environment_variables = optional(map(string), {})
      secrets               = optional(map(string), {})

      command     = optional(list(string))
      entry_point = optional(list(string))

      port_mappings = optional(list(object({
        container_port = number
        protocol       = optional(string, "tcp")
      })), [])

      read_only_root_filesystem = optional(bool)

      health_check = optional(object({
        command      = list(string)
        interval     = optional(number, 30)
        timeout      = optional(number, 5)
        retries      = optional(number, 3)
        start_period = optional(number, 0)
      }), null)

      start_timeout_seconds = optional(number)
      stop_timeout_seconds  = optional(number)

      dependency_rank = optional(number, 0)

      depends_on = optional(list(object({
        container_name = string
        condition      = string
      })), [])

      mount_points = optional(list(object({
        source_volume  = string
        container_path = string
        read_only      = optional(bool, false)
      })), [])
    })), {})
  }))

  default = {}

  validation {
    condition = alltrue([
      for service in values(var.services) :
      can(regex("@sha256:[0-9a-f]{64}$", service.image))
    ])

    error_message = "Every ECS service image must be pinned to a SHA-256 digest using repository@sha256:<64 hex characters>."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.container_port >= 1 &&
      service.container_port <= 65535
    ])

    error_message = "Each ECS service container_port must be between 1 and 65535."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      contains(["X86_64", "ARM64"], service.cpu_architecture)
    ])

    error_message = "Each ECS service cpu_architecture must be X86_64 or ARM64."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.desired_count >= 0
    ])

    error_message = "Each ECS service desired_count must be zero or greater."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      (
        service.cpu == 256 &&
        contains([512, 1024, 2048], service.memory)
      ) ||
      (
        service.cpu == 512 &&
        contains([1024, 2048, 3072, 4096], service.memory)
      ) ||
      (
        service.cpu == 1024 &&
        service.memory >= 2048 &&
        service.memory <= 8192 &&
        service.memory % 1024 == 0
      ) ||
      (
        service.cpu == 2048 &&
        service.memory >= 4096 &&
        service.memory <= 16384 &&
        service.memory % 1024 == 0
      ) ||
      (
        service.cpu == 4096 &&
        service.memory >= 8192 &&
        service.memory <= 30720 &&
        service.memory % 1024 == 0
      ) ||
      (
        service.cpu == 8192 &&
        service.memory >= 16384 &&
        service.memory <= 61440 &&
        service.memory % 4096 == 0
      ) ||
      (
        service.cpu == 16384 &&
        service.memory >= 32768 &&
        service.memory <= 122880 &&
        service.memory % 8192 == 0
      )
    ])

    error_message = "Each ECS service must use a valid AWS Fargate CPU and memory combination."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.scaling == null ? true : (
        service.scaling.alb_requests_per_target == null
        ? true
        : (
          service.target_group_arn != null &&
          service.alb_request_resource_label != null
        )
      )
    ])

    error_message = "ALB request-count scaling requires both target_group_arn and alb_request_resource_label."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.health_check == null ? true : (
        service.health_check.command == null ? false : (
          contains(
            ["CMD", "CMD-SHELL"],
            try(service.health_check.command[0], "")
          ) &&
          (
            try(service.health_check.command[0], "") == "CMD-SHELL"
            ? length(service.health_check.command) == 2
            : length(service.health_check.command) >= 2
          ) &&
          alltrue([
            for element in service.health_check.command :
            element == null ? false : trimspace(element) != ""
          ])
        )
      )
    ])

    error_message = "ECS health_check.command must start with CMD or CMD-SHELL. CMD-SHELL requires exactly two elements; CMD requires an executable (additional arguments are optional). All command elements must be nonempty."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.health_check == null ? true : (
        service.health_check.interval >= 5 &&
        service.health_check.interval <= 300 &&
        service.health_check.interval == floor(service.health_check.interval) &&

        service.health_check.timeout >= 2 &&
        service.health_check.timeout <= 60 &&
        service.health_check.timeout == floor(service.health_check.timeout) &&

        service.health_check.retries >= 1 &&
        service.health_check.retries <= 10 &&
        service.health_check.retries == floor(service.health_check.retries) &&

        service.health_check.start_period >= 0 &&
        service.health_check.start_period <= 300 &&
        service.health_check.start_period == floor(service.health_check.start_period)
      )
    ])

    error_message = "ECS health_check timing values must be whole numbers within AWS limits: interval 5-300, timeout 2-60, retries 1-10, and start_period 0-300."
  }

  validation {
    condition = alltrue(flatten([
      for service_name, service in var.services : [
        for sidecar_name, sidecar in service.sidecars :
        sidecar_name != service_name &&
        can(regex("^[A-Za-z0-9_-]{1,255}$", sidecar_name)) &&
        can(regex("@sha256:[0-9a-f]{64}$", sidecar.image))
      ]
    ]))

    error_message = "Sidecar names must be valid ECS container names, must differ from the primary container name, and images must be pinned to SHA-256 digests."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :
        length(setintersection(
          toset(keys(sidecar.environment_variables)),
          toset(keys(sidecar.secrets))
        )) == 0
      ]
    ]))

    error_message = "A sidecar cannot define the same environment variable name in both environment_variables and secrets."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for timeout in concat(
          [
            service.start_timeout_seconds,
            service.stop_timeout_seconds
          ],
          flatten([
            for sidecar in values(service.sidecars) : [
              sidecar.start_timeout_seconds,
              sidecar.stop_timeout_seconds
            ]
          ])
        ) :
        timeout == null ? true : (
          timeout >= 2 &&
          timeout <= 120 &&
          timeout == floor(timeout)
        )
      ]
    ]))

    error_message = "Container start and stop timeouts must be whole numbers between 2 and 120 seconds."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :
        sidecar.health_check == null ? true : (
          sidecar.health_check.command == null ? false : (
            contains(
              ["CMD", "CMD-SHELL"],
              try(sidecar.health_check.command[0], "")
            ) &&
            (
              try(sidecar.health_check.command[0], "") == "CMD-SHELL"
              ? length(sidecar.health_check.command) == 2
              : length(sidecar.health_check.command) >= 2
            ) &&
            alltrue([
              for element in sidecar.health_check.command :
              element == null ? false : trimspace(element) != ""
            ])
          )
        )
      ]
    ]))

    error_message = "Sidecar health_check.command must start with CMD or CMD-SHELL, contain the required arguments, and have no empty elements."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :
        sidecar.health_check == null ? true : (
          sidecar.health_check.interval >= 5 &&
          sidecar.health_check.interval <= 300 &&
          sidecar.health_check.interval == floor(sidecar.health_check.interval) &&

          sidecar.health_check.timeout >= 2 &&
          sidecar.health_check.timeout <= 60 &&
          sidecar.health_check.timeout == floor(sidecar.health_check.timeout) &&

          sidecar.health_check.retries >= 1 &&
          sidecar.health_check.retries <= 10 &&
          sidecar.health_check.retries == floor(sidecar.health_check.retries) &&

          sidecar.health_check.start_period >= 0 &&
          sidecar.health_check.start_period <= 300 &&
          sidecar.health_check.start_period == floor(sidecar.health_check.start_period)
        )
      ]
    ]))

    error_message = "Sidecar health-check timings must be whole numbers within AWS limits: interval 5-300, timeout 2-60, retries 1-10, and start_period 0-300."
  }

  validation {
    condition = alltrue([
      for service_name, service in var.services :

      length(distinct([
        for dependency in service.depends_on :
        dependency.container_name
      ])) == length(service.depends_on) &&

      alltrue([
        for dependency in service.depends_on :

        contains(keys(service.sidecars), dependency.container_name) &&

        contains(
          ["START", "HEALTHY", "COMPLETE", "SUCCESS"],
          dependency.condition
        ) &&

        (
          dependency.condition != "HEALTHY" ||
          try(
            service.sidecars[dependency.container_name].health_check != null,
            false
          )
        ) &&

        (
          !contains(["COMPLETE", "SUCCESS"], dependency.condition) ||
          try(
            service.sidecars[dependency.container_name].essential == false,
            false
          )
        )
      ])
    ])

    error_message = "Primary container dependencies must reference distinct, existing sidecars with valid ECS conditions. HEALTHY requires a health check; COMPLETE and SUCCESS require a nonessential sidecar."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :
        sidecar.dependency_rank >= 0 &&
        sidecar.dependency_rank == floor(sidecar.dependency_rank)
      ]
    ]))

    error_message = "Sidecar dependency_rank must be a non-negative whole number."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar_name, sidecar in service.sidecars : (

          length(distinct([
            for dependency in sidecar.depends_on :
            dependency.container_name
          ])) == length(sidecar.depends_on) &&

          alltrue([
            for dependency in sidecar.depends_on :

            contains(keys(service.sidecars), dependency.container_name) &&

            dependency.container_name != sidecar_name &&

            contains(
              ["START", "HEALTHY", "COMPLETE", "SUCCESS"],
              dependency.condition
            ) &&

            (
              dependency.condition != "HEALTHY" ||
              try(
                service.sidecars[dependency.container_name].health_check != null,
                false
              )
            ) &&

            (
              !contains(["COMPLETE", "SUCCESS"], dependency.condition) ||
              try(
                service.sidecars[dependency.container_name].essential == false,
                false
              )
            ) &&

            try(
              service.sidecars[dependency.container_name].dependency_rank <
              sidecar.dependency_rank,
              false
            )
          ])
        )
      ]
    ]))

    error_message = "Sidecar dependencies must reference distinct, existing sidecars with lower dependency ranks and valid ECS conditions. HEALTHY requires a health check; COMPLETE and SUCCESS require nonessential prerequisites."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for name in service.task_volumes :
        can(regex("^[A-Za-z0-9_-]{1,255}$", name))
      ]
    ]))

    error_message = "Task volume names must be 1-255 characters and contain only letters, numbers, hyphens, or underscores."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for mounts in concat(
          [service.mount_points],
          [
            for sidecar in values(service.sidecars) :
            sidecar.mount_points
          ]
          ) : (
          length(distinct([
            for mount in mounts : mount.container_path
          ])) == length(mounts) &&

          alltrue([
            for mount in mounts :
            contains(service.task_volumes, mount.source_volume) &&
            startswith(mount.container_path, "/") &&
            mount.container_path != "/" &&
            trimspace(mount.container_path) == mount.container_path
          ])
        )
      ]
    ]))

    error_message = "Container mount points must reference declared task volumes, use absolute non-root paths without surrounding whitespace, and have unique destination paths per container."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.ephemeral_storage_gib == null ? true : (
        service.ephemeral_storage_gib >= 21 &&
        service.ephemeral_storage_gib <= 200 &&
        service.ephemeral_storage_gib == floor(service.ephemeral_storage_gib)
      )
    ])

    error_message = "Fargate ephemeral_storage_gib must be a whole number between 21 and 200 GiB when explicitly configured."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :

        (sidecar.cpu_units == null ? true : (
          sidecar.cpu_units >= 1 &&
          sidecar.cpu_units < service.cpu &&
          sidecar.cpu_units == floor(sidecar.cpu_units)
        )) &&

        (sidecar.memory_limit_mib == null ? true : (
          sidecar.memory_limit_mib >= 6 &&
          sidecar.memory_limit_mib <= service.memory &&
          sidecar.memory_limit_mib == floor(sidecar.memory_limit_mib)
        )) &&

        (sidecar.memory_reservation_mib == null ? true : (
          sidecar.memory_reservation_mib >= 6 &&
          sidecar.memory_reservation_mib < service.memory &&
          sidecar.memory_reservation_mib == floor(sidecar.memory_reservation_mib)
        )) &&

        (
          sidecar.memory_limit_mib == null ||
          sidecar.memory_reservation_mib == null
          ? true
          : sidecar.memory_limit_mib > sidecar.memory_reservation_mib
        )
      ]
    ]))

    error_message = "Sidecar CPU and memory settings must be valid whole numbers within the task limits. A memory hard limit must exceed its soft reservation."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :

      sum(concat(
        [0],
        [
          for sidecar in values(service.sidecars) :
          coalesce(sidecar.cpu_units, 0)
        ]
      )) < service.cpu &&

      sum(concat(
        [0],
        [
          for sidecar in values(service.sidecars) :
          sidecar.memory_reservation_mib != null
          ? sidecar.memory_reservation_mib
          : coalesce(sidecar.memory_limit_mib, 0)
        ]
      )) < service.memory
    ])

    error_message = "Combined sidecar CPU shares and memory reservations must remain below the task-level CPU and memory allocations."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :
        alltrue([
          for args in [sidecar.command, sidecar.entry_point] :
          args == null ? true : (
            length(args) > 0 &&
            alltrue([
              for arg in args :
              arg == null ? false : trimspace(arg) != ""
            ])
          )
        ])
      ]
    ]))

    error_message = "Sidecar command and entry_point overrides must contain at least one nonempty string."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for sidecar in values(service.sidecars) :
        alltrue([
          for port in sidecar.port_mappings :
          port.container_port >= 1 &&
          port.container_port <= 65535 &&
          port.container_port == floor(port.container_port) &&
          contains(["tcp", "udp"], port.protocol)
        ])
      ]
    ]))

    error_message = "Sidecar ports must be whole numbers between 1 and 65535, using tcp or udp."
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      length(distinct(concat(
        [service.container_port],
        flatten([
          for sidecar in values(service.sidecars) : [
            for port in sidecar.port_mappings :
            port.container_port
          ]
        ])
        ))) == 1 + sum(concat(
        [0],
        [
          for sidecar in values(service.sidecars) :
          length(sidecar.port_mappings)
        ]
      ))
    ])

    error_message = "The primary container and sidecars must not declare duplicate container ports within the same ECS task."
  }
}

variable "logs_cmk_arn" {
  description = "ARN of the customer-managed KMS key used to encrypt ECS CloudWatch log groups"
  type        = string
}

variable "execution_policy_ids" {
  description = "ECS task execution IAM policy IDs keyed by service name, used as service launch-readiness dependencies"
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for service_name in keys(var.services) :
      contains(keys(var.execution_policy_ids), service_name)
    ])

    error_message = "execution_policy_ids must contain an entry for every configured ECS service."
  }
}

variable "task_role_policy_attachment_ids" {
  description = "Optional application task-role managed-policy attachment IDs keyed by service for launch readiness"
  type        = map(set(string))
  default     = {}

  validation {
    condition = alltrue([
      for service_name in keys(var.task_role_policy_attachment_ids) :
      contains(keys(var.services), service_name)
    ])

    error_message = "task_role_policy_attachment_ids keys must match configured ECS services."
  }
}

variable "security_policy_rule_ids" {
  description = "Cross-component Security Group rule IDs keyed by service name, used as service launch-readiness dependencies"
  type        = map(set(string))
  default     = {}

  validation {
    condition = alltrue([
      for service_name in keys(var.services) :
      contains(keys(var.security_policy_rule_ids), service_name)
    ])

    error_message = "security_policy_rule_ids must contain an entry for every configured ECS service."
  }
}

variable "availability_zone_rebalancing" {
  description = "Whether ECS Availability Zone is explicitly managed for services"
  type        = string
  default     = null

  validation {
    condition = (
      var.availability_zone_rebalancing == null ||
      contains(
        ["ENABLED", "DISABLED"],
        var.availability_zone_rebalancing
      )
    )

    error_message = "availability_zone_rebalancing must be null, ENABLED, or DISABLED."
  }
}

variable "force_delete" {
  description = "Whether ECS services may be forcibly deleted without first scaling to zero."
  type        = bool
}