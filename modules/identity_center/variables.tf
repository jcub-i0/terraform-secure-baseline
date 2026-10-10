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

variable "enable_secops_administrator" {
  description = "Determines whether SecOps-Administrator resources are deployed"
  type        = bool
  default     = false
}

variable "secops_administrator_group_name" {
  description = "Name of the SecOps-Administrator Identity Center group"
  type        = string
  default     = null

  validation {
    condition = (
      !var.enable_secops_administrator ||
      try(trimspace(var.secops_administrator_group_name), "") != ""
    )

    error_message = "secops_administrator_group_name must be set when enable_secops_administrator is true."
  }
}
