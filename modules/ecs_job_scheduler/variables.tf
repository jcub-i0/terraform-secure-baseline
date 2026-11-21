variable "name_prefix" {
  description = "Application naming prefix for Scheduler-owned resources."
  type        = string
}

variable "environment" {
  description = "Application environment used for resource tagging."
  type        = string
}

variable "broker_request_queue_arn" {
  description = "Existing application-owned SQS queue receiving protected job launch requests."
  type        = string
  default     = null

  validation {
    condition = (
      length(var.schedules) == 0 ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$",
        var.broker_request_queue_arn
      ))
    )

    error_message = "Configured schedules require an exact SQS broker request queue ARN."
  }
}

variable "schedules" {
  description = "Optional job schedules. Every schedule is disabled by default."

  type = map(object({
    job_key             = string
    schedule_expression = string
    timezone            = optional(string, "UTC")
    enabled             = optional(bool, false)

    maximum_retry_attempts       = optional(number, 3)
    maximum_event_age_in_seconds = optional(number, 3600)
  }))

  default = {}

  validation {
    condition = alltrue([
      for schedule in values(var.schedules) :
      length(trimspace(schedule.job_key)) > 0 &&
      can(regex(
        "^(cron|rate|at)\\(.+\\)$",
        schedule.schedule_expression
      )) &&
      length(trimspace(schedule.timezone)) > 0 &&
      schedule.maximum_retry_attempts >= 0 &&
      schedule.maximum_retry_attempts <= 185 &&
      schedule.maximum_event_age_in_seconds >= 60 &&
      schedule.maximum_event_age_in_seconds <= 86400
    ])

    error_message = "Schedules require a job key, valid expression shape, timezone, and supported retry bounds."
  }
}

variable "dlq_kms_key_arn" {
  description = "Existing customer-managed KMS key ARN for Scheduler DLQ encryption."
  type        = string
  default     = null

  validation {
    condition = (
      length(var.schedules) == 0 ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.dlq_kms_key_arn
      ))
    )

    error_message = "Nonempty schedules require an exact customer-managed KMS key ARN for DLQ encryption."
  }
}

variable "broker_request_queue_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN encrypting the existing broker request queue."
  type        = string
  default     = null

  validation {
    condition = (
      var.broker_request_queue_kms_key_arn == null ||
      can(regex(
        "^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$",
        var.broker_request_queue_kms_key_arn
      ))
    )

    error_message = "Broker queue KMS key must be an exact customer-managed key ARN."
  }
}