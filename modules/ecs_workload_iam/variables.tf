variable "name_prefix" {
  description = "Naming prefix for workload IAM roles and inline policies."
  type        = string
}

variable "environment" {
  description = "Environment used for resource tagging."
  type        = string
}

variable "account_id" {
  description = "AWS account ID used by the ECS trust conditions and managed-policy ARN restriction."
  type        = string
}

variable "primary_region" {
  description = "AWS Region used by the ECS aws:SourceArn trust condition."
  type        = string
}

variable "workloads" {
  description = "ECS services and standalone jobs requiring task execution and application task IAM roles, keyed by stable workload name"

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
      for service in values(var.workloads) : [
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
      for service in values(var.workloads) : [
        for parameter_arn in service.execution_ssm_parameter_arns :
        can(regex("^arn:(aws|aws-us-gov|aws-cn):ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", parameter_arn))
      ]
    ]))

    error_message = "execution_ssm_parameter_arns must contain full SSM parameter ARNs without wildcard characters."
  }

  # kms:Decrypt Resources require key ARNs, including mrk- keys, not aliases.
  validation {
    condition = alltrue(flatten([
      for service in values(var.workloads) : [
        for key_arn in service.task_execution_kms_key_arns :
        can(regex("^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", key_arn))
      ]
    ]))

    error_message = "task_execution_kms_key_arns must contain exact KMS key ARNs without wildcards, not key IDs or aliases."
  }

  validation {
    condition = alltrue(flatten([
      for service in values(var.workloads) : [
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
