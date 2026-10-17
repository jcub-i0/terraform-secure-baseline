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
      for service in values(var.ecs_services) :
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

    error_message = "ECS health_check.command must start with CMD or CMD-SHELL. CMD-SHELL requires exactly two elements; CMD requires an executable and at least one argument. All command elements must be nonempty."
  }

  validation {
    condition = alltrue([
      for service in values(var.ecs_services) :
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