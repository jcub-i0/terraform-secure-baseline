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