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

variable "secops_operator_group_name" {
  description = "Name of the SecOps-Operator Identity Center group"
  type        = string
}

variable "secops_analyst_group_name" {
  description = "Name of the SecOps-Analyst IAM group"
  type        = string
  default     = null
  
  validation {
    condition = !var.enable_secops_analyst && var.secops_analyst_group_name == null
    error_message = "'enable_secops_analyst' must be set to 'true' when 'secops_analyst_group_name' is set"
  }
}

variable "secops_engineer_group_name" {
  description = "Name of the SecOps-Engineer IAM group"
  type        = string
  default     = null

  validation {
    condition = !var.enable_secops_engineer && var.secops_engineer_group_name == null
    error_message = "'enable_secops_engineer' must be set to 'true' when 'secops_engineer_group_name' is set"
  }
}

variable "customer_managed_policy_path" {
  description = "Path of customer managed IAM policies used by permission sets"
  type        = string
  default     = "/"

  validation {
    condition     = var.customer_managed_policy_path != ""
    error_message = "'customer_managed_policy_path' cannot be empty"
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
    error_message = "'logs_s3_readonly_policy_name' must be set when 'enable_secops_analyst' or 'enable_secops_engineer' is set to 'true'"
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
    error_message = "'logs_cmk_decrypt_policy_name' must be set when 'enable_secops_analyst' or 'enable_secops_engineer' is set to 'true'"
  }
}