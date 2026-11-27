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

variable "execution_ledger_cmk_arn" {
  description = "Application-owned customer-managed KMS key ARN for execution ledger encryption"
  type        = string
  default     = null

  validation {
    condition = (
      length(var.jobs) == 0 ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.execution_ledger_cmk_arn
      ))
    )

    error_message = "Configured jobs require an exact customer-managed KMS key ARN for the execution ledger."
  }
}

variable "broker_log_cmk_arn" {
  description = "Application-owned CMK ARN for broker Lambda logs"
  type        = string
  default     = null

  validation {
    condition = (
      length(var.jobs) == 0 ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.broker_log_cmk_arn
      ))
    )

    error_message = "Configured jobs require an exact CMK ARN for broker Lambda logs."
  }
}

variable "cloudwatch_retention_days" {
  description = "CloudWatch Logs retention period supplied by the application composition"
  type        = number
  default     = null

  validation {
    condition = (
      length(var.jobs) == 0 ||
      var.cloudwatch_retention_days != null
    )

    error_message = "Configured jobs require an explicit CloudWatch Logs retention period."
  }
}

variable "broker_lambda_package" {
  description = "Approved version-pinned S3 ZIP artifact for the broker Lambda function. Null disables function creation"

  type = object({
    bucket     = string
    key        = string
    version_id = string
  })

  default = null

  validation {
    condition = var.broker_lambda_package == null ? true : (
      length(var.jobs) > 0 &&
      length(trimspace(var.broker_lambda_package.bucket)) > 0 &&
      length(trimspace(var.broker_lambda_package.key)) > 0 &&
      length(trimspace(var.broker_lambda_package.version_id)) > 0 &&
      var.broker_lambda_package.version_id != "null"
    )

    error_message = "A broker Lambda package requires configured jobs and a nonempty S3 bucket, key, and object version ID."
  }
}

variable "broker_lambda_cmk_arn" {
  description = "Approved customer-managed KMS key ARN for Lambda environment encryption"
  type        = string
  default     = null

  validation {
    condition = (
      var.broker_lambda_package == null ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.broker_lambda_cmk_arn
      ))
    )

    error_message = "A configured broker Lambda package requires an exact customer-managed KMS key ARN."
  }
}

variable "alarm_topic_arn" {
  description = "Existing approved SNS topic for broker processing-failure alarms"
  type        = string
  default     = null

  validation {
    condition = (
      length(var.jobs) == 0 ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$",
        var.alarm_topic_arn
      ))
    )

    error_message = "Configured jobs require an exact SNS alarm topic ARN."
  }
}

variable "admission_gate" {
  description = "Protected foundation gate references. Null adds no gate-access permissions."
  type = object({
    table_arn = string
    cmk_arn   = string
  })
  default = null

  validation {
    condition = var.admission_gate == null ? true : try(
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):dynamodb:[a-z0-9-]+:[0-9]{12}:table/[A-Za-z0-9_.-]+$",
        var.admission_gate.table_arn
      )) &&
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.admission_gate.cmk_arn
      )) &&
      alltrue([
        for arn in [var.admission_gate.table_arn, var.admission_gate.cmk_arn] :
        regex("^arn:([^:]+):[^:]+:([^:]+):([^:]+):", arn) ==
        regex("^arn:([^:]+):[^:]+:([^:]+):([^:]+):", var.approved_cluster_arn)
      ]) &&
      split("/", var.admission_gate.table_arn)[1] != "${var.name_prefix}-job-execution-ledger",
      false
    )
    error_message = "The gate requires exact table/key ARNs in the approved cluster's partition, account, and Region, and must be separate from the execution ledger."
  }
}