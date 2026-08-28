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

variable "compute_private_subnet_ids" {
  description = "Compute-private subnet IDs used by Fargate tasks."
  type        = set(string)
}

variable "cloudwatch_retention_days" {
  description = "CloudWatch Logs retention period for ECS service log groups."
  type        = number
}

variable "platform_version" {
  description = "AWS Fargate platform version used by ECS services."
  type        = string
  default     = "1.4.0"
}

variable "services" {
  description = "ECS/Fargate services keyed by stable service name"

  type = map(object({
    image          = string
    container_port = number
    cpu            = number
    memory         = number
    desired_count  = optional(number, 1)

    execution_role_arn = string
    task_role_arn      = string

    target_group_arn = optional(string)

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