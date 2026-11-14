
variable "name_prefix" {
  description = "Naming prefix for standalone ECS jobs."
  type        = string
}

variable "environment" {
  description = "Environment used for resource tagging."
  type        = string
}

variable "primary_region" {
  description = "AWS Region for CloudWatch Logs."
  type        = string
}

variable "logs_cmk_arn" {
  description = "KMS key ARN for encrypted job logs."
  type        = string
}

variable "cloudwatch_retention_days" {
  description = "Retention period for job logs."
  type        = number
}

variable "tasks" {
  description = "Standalone Fargate jobs keyed by stable job name."

  type = map(object({
    image              = string
    cpu                = number
    memory             = number
    execution_role_arn = string
    task_role_arn      = string

    cpu_architecture      = optional(string, "X86_64")
    command               = optional(list(string))
    environment_variables = optional(map(string), {})
    secrets               = optional(map(string), {})

    task_volumes = optional(set(string), [])

    ephemeral_storage_gib = optional(number)

    mount_points = optional(list(object({
      source_volume  = string
      container_path = string
      read_only      = optional(bool, false)
    })), [])
  }))

  default = {}

  validation {
    condition = alltrue([
      for task in values(var.tasks) :
      can(regex(
        "^[^[:space:]@]+@sha256:[0-9a-f]{64}$",
        task.image
      ))
    ])

    error_message = "Every job image must use an immutable repository@sha256:<64 lowercase hexadecimal characters> reference."
  }

  validation {
    condition = alltrue([
      for task in values(var.tasks) :
      alltrue([
        for mount in task.mount_points :
        contains(task.task_volumes, mount.source_volume)
      ])
    ])

    error_message = "Every mount point must reference a volume declared for its job."
  }
}
