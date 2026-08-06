variable "identity_center_workloads" {
  description = "Identity Center configuraiton for workload accounts"

  type = map(object({
    account_id                   = string
    primary_region               = string
    enable_secops_analyst        = optional(bool, false)
    enable_secops_engineer       = optional(bool, false)
    logs_s3_readonly_policy_name = string
    logs_cmk_decrypt_policy_name = string
  }))

  validation {
    condition = alltrue([
      for environment, configuration in var.idenitty_center_workloads :
      contains(["dev", "staging", "prod"], environment)
    ])

    error_message = "Identity Center workload keys must be dev, staging, or prod."
  }

  validation {
    condition = alltrue([
      for configuration in values(var.identity_center_workloads) :
      can(regex("^[0-9]{12}$", configuration.account_id))
    ])

    error_message = "Each workload account ID must contain exactly 12 digits."
  }
}

variable "identity_center_secops" {
  description = "Identity Center configuration for the security-operations account"

  type = object({
    account_id = string
    enable_secops_analyst = optional(bool, false)
    enable_secops_engineer = optional(bool, false)
    logs_s3_readonly_policy_name = optional(string)
    logs_cmk_decrypt_policy_name = optional(string)
  })

  validation {
    condition = can(regex(
      "^[0-9]{12}$",
      var.identity_center_secops.account_id
    ))

    error_message = "The Security-Operations account ID must contain exactly 12 digits."
  }
}

variable "enable_secops_analyst_secops" {
  description = "Determines whether SecOps-Analyst resources are deployed in the 'security-operations' env"
  type        = bool
  default     = false
}

variable "enable_secops_engineer_secops" {
  description = "Determines whether SecOps-Engineer resources are deployed in the 'security-operations' env"
  type        = bool
  default     = false
}

variable "account_id_secops" {
  description = "ID of the AWS account managing the 'security-operations' environment"
  type        = string
}

variable "logs_s3_readonly_policy_name_secops" {
  description = "'Name' attribute of the 'security-operations' env's logs_s3_readonly policy"
  type        = string
  default     = null
}

variable "logs_cmk_decrypt_policy_name_secops" {
  description = "'Name' attribute of the 'security-operations' env's logs_cmk_decrypt policy"
  type        = string
  default     = null
}