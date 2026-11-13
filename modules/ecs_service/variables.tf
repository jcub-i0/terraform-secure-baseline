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
    condition = alltrue(flatten([
      for service in values(var.services) : [
        for container in concat([service], values(service.sidecars)) :
        can(regex("^[^[:space:]\\p{Z}\\x{0085}@]+@sha256:[0-9a-f]{64}$", container.image))
      ]
    ]))

    error_message = "Every primary and sidecar image must use a nonempty repository@sha256:<64 lowercase hex characters> reference without whitespace or extra suffixes."
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
      for service_name, service in var.services :
      !contains(keys(service.sidecars), service_name)
    ])

    error_message = "Sidecar names must differ from the primary container name."
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
        for sidecar_name, sidecar in service.sidecars : (

          length(distinct([
            for dependency in sidecar.depends_on :
            dependency.container_name
          ])) == length(sidecar.depends_on) &&

          alltrue([
            for dependency in sidecar.depends_on :

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
            trimspace(mount.container_path) == mount.container_path &&
            alltrue([
              for component in split("/", trimprefix(mount.container_path, "/")) :
              !contains(["", ".", ".."], component)
            ])
          ])
        )
      ]
    ]))

    error_message = "Container mount points must reference declared task volumes and use unique, canonical absolute non-root paths per container: no empty, '.' or '..' components, repeated/trailing separators, or surrounding whitespace."
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
