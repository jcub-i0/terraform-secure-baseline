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

    environment = optional(map(string), {})
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
}

variable "logs_cmk_arn" {
  description = "ARN of the customer-managed KMS key used to encrypt ECS CloudWatch log groups"
  type = string
}