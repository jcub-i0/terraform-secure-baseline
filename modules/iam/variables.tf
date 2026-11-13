variable "cloud_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "cloudtrail_log_group_arn" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "secrets_manager_cmk_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "centralized_logs_bucket_arn" {
  type = string
}

variable "flowlogs_firehose_delivery_stream_arn" {
  type = string
}

variable "flowlogs_log_group_arn" {
  type = string
}

variable "secops_event_bus_arn" {
  type = string
}

variable "threat_intel_api_keys_arn" {
  type = string
}

variable "lambda_ip_enrichment_log_group_arn" {
  type = string
}

variable "break_glass_trusted_principal_arns" {
  type = list(string)
}

variable "lambda_ec2_isolation_dlq_arn" {
  type = string
}

variable "lambda_ec2_rollback_dlq_arn" {
  type = string
}

variable "lambda_ip_enrichment_dlq_arn" {
  type = string
}

variable "alb_access_logs_bucket_arn" {
  description = "Optional ALB access-log bucket ARN for the shared read-only logs policy"
  type        = string
  default     = null
}

variable "ecs_iam_services" {
  description = "ECS services requiring task execution and task IAM roles"

  type = map(object({
    ecr_repository_arns                 = set(string)
    guardduty_agent_ecr_repository_arns = optional(set(string), [])
    log_group_arns                      = set(string)

    execution_secret_arns         = optional(set(string), [])
    execution_ssm_parameter_arns  = optional(set(string), [])
    task_execution_kms_key_arns   = optional(set(string), [])
    task_role_managed_policy_arns = optional(set(string), [])
  }))

  default = {}

  # Both pull inventories are IAM Resources. GuardDuty repositories may belong
  # to another account; require exact repository ARNs without restricting owner.
  validation {
    condition = alltrue(flatten([
      for service in values(var.ecs_iam_services) : [
        for repository_arn in setunion(service.ecr_repository_arns, service.guardduty_agent_ecr_repository_arns) :
        can(regex(
          "^arn:(aws|aws-us-gov|aws-cn):ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9]+((\\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\\.|_|__|-+)[a-z0-9]+)*)*$",
          repository_arn
        ))
      ]
    ]))

    error_message = "ecr_repository_arns and guardduty_agent_ecr_repository_arns must contain exact ECR repository ARNs in supported AWS partitions, without wildcard resources."
  }

  # These inputs are used verbatim as IAM Resources, so ECS parameter names
  # and paths must already have been resolved to full, exact parameter ARNs.
  validation {
    condition = alltrue(flatten([
      for service in values(var.ecs_iam_services) : [
        for parameter_arn in service.execution_ssm_parameter_arns :
        can(regex("^arn:(aws|aws-us-gov|aws-cn):ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", parameter_arn))
      ]
    ]))

    error_message = "execution_ssm_parameter_arns must contain full SSM parameter ARNs without wildcard characters."
  }

  # kms:Decrypt Resources require key ARNs, including mrk- keys, not aliases.
  validation {
    condition = alltrue(flatten([
      for service in values(var.ecs_iam_services) : [
        for key_arn in service.task_execution_kms_key_arns :
        can(regex("^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", key_arn))
      ]
    ]))

    error_message = "task_execution_kms_key_arns must contain exact KMS key ARNs without wildcards, not key IDs or aliases."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.ecs_iam_services) : [
        for secret_arn in service.execution_secret_arns :
        can(regex(
          "^arn:(aws|aws-us-gov|aws-cn):secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$",
          secret_arn
        ))
      ]
    ]))

    error_message = "execution_secret_arns must contain exact full Secrets Manager secret ARNs, including the six-character suffix, without wildcard resources or ECS selectors."
  }
}
