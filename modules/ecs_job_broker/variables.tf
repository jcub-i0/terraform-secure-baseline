variable "name_prefix" {
  description = "Resource naming prefix for the application."
  type        = string
}

variable "environment" {
  description = "Application environment identifier."
  type        = string
}

variable "approved_cluster_arn" {
  description = "Exact foundation-owned ECS cluster ARN"
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Platform-governed IAM permissions boundary for broker and launcher roles"
  type        = string
  nullable    = false
}

variable "jobs" {
  description = "Approved standalone jobs, keyed by job name"
  type = map(object({
    task_definition_arn = string
    execution_role_arn  = string
    task_role_arn       = string
  }))

  default = {}

  validation {
    condition = alltrue([
      for job in values(var.jobs) :
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):ecs:[a-z0-9-]+:[0-9]{12}:task-definition/[A-Za-z0-9_-]+:[1-9][0-9]*$",
        job.task_definition_arn
      ))
    ])

    error_message = "Each job must reference an exact ECS task-definition revision ARN."
  }
}

variable "broker_request_queue_cmk_arn" {
  description = "Application-owned CMK ARN for broker request queue encryption"
  type        = string
  default     = null

  validation {
    condition = (
      length(var.jobs) == 0 ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.broker_request_queue_cmk_arn
      ))
    )

    error_message = "Configured jobs require an exact CMK ARN for the broker request queue."
  }
}