variable "environment" {
  description = "Environment name"
  type        = string
}

variable "account_id" {
  description = "ID of the AWS account managing this environment"
  type        = string
}

variable "secops_event_bus_arn" {
  description = "ARN of the SecOps Event Bus"
  type        = string
  default     = null

  validation {
    condition = !(
      var.enable_secops_operator &&
      var.secops_event_bus_arn == null
    )

    error_message = "secops_event_bus_arn must be set when enable_secops_operator is true."
  }
}

variable "enable_secops_analyst" {
  description = "Determines whether SecOps-Analyst resources are deployed"
  type        = bool
  default     = false
}

variable "enable_secops_engineer" {
  description = "Determines whether SecOps-Engineer resources are deployed"
  type        = bool
  default     = false
}

variable "enable_secops_operator" {
  description = "Determines whether SecOps-Operator resources are deployed"
  type        = bool
  default     = true
}

variable "secops_operator_group_name" {
  description = "Name of the SecOps-Operator Identity Center group"
  type        = string
  default     = null

  validation {
    condition = (
      !var.enable_secops_operator ||
      try(trimspace(var.secops_operator_group_name), "") != ""
    )

    error_message = "secops_operator_group_name must be set when enable_secops_operator is true."
  }
}

variable "secops_analyst_group_name" {
  description = "Name of the SecOps-Analyst IAM group"
  type        = string
  default     = null

  validation {
    condition = (
      !var.enable_secops_analyst ||
      try(trimspace(var.secops_analyst_group_name), "") != ""
    )

    error_message = "secops_analyst_group_name must be set when enable_secops_analyst is true."
  }
}

variable "secops_engineer_group_name" {
  description = "Name of the SecOps-Engineer IAM group"
  type        = string
  default     = null

  validation {
    condition = (
      !var.enable_secops_engineer ||
      try(trimspace(var.secops_engineer_group_name), "") != ""
    )

    error_message = "secops_engineer_group_name must be set when enable_secops_engineer is true."
  }
}

variable "customer_managed_policy_path" {
  description = "Path of customer managed IAM policies used by permission sets"
  type        = string
  default     = "/"

  validation {
    condition     = var.customer_managed_policy_path != ""
    error_message = "'customer_managed_policy_path_${var.environment}' cannot be empty"
  }
}

variable "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the logs_s3_readonly policy (set after 'baseline' is deployed)"
  type        = string
  default     = null

  validation {
    condition = !(
      (var.enable_secops_analyst || var.enable_secops_engineer)
      && var.logs_s3_readonly_policy_name == null
    )
    error_message = "'logs_s3_readonly_policy_name_${var.environment}' must be set when 'enable_secops_analyst_${var.environment}' or 'enable_secops_engineer_${var.environment}' is set to 'true'"
  }
}

variable "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the logs_cmk_decrypt policy (set after 'baseline' is deployed)"
  type        = string
  default     = null

  validation {
    condition = !(
      (var.enable_secops_analyst || var.enable_secops_engineer)
      && var.logs_cmk_decrypt_policy_name == null
    )
    error_message = "'logs_cmk_decrypt_policy_name_${var.environment}' must be set when 'enable_secops_analyst' or 'enable_secops_engineer_${var.environment}' is set to 'true'"
  }
}