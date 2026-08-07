variable "cloud_name" {
  description = "Name of the cloud platform"
  type        = string
}

variable "environment" {
  description = "Name of the specialized security account environment"
  type        = string

  validation {
    condition     = var.environment == "security-operations"
    error_message = "environment must be security-operations."
  }
}

variable "primary_region" {
  description = "Primary and Security Hub home Region"
  type        = string
}

variable "account_id" {
  description = "AWS account ID of the security-operations account"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "enable_securityhub_organization_configuration" {
  description = "Enable Security Hub central organization configuration after delegated administration is configured"
  type        = bool
  default     = false
}

variable "securityhub_cspm_account_policies" {
  description = "Per-account Security Hub CSPM central configuration policies and associations"

  type = map(object({
    create_policy    = optional(bool, false)
    associate_policy = optional(bool, false)
    enabled_standards = optional(set(string), [
      "aws_fsbp",
      "cis_5_0"
    ])
    disabled_control_identifiers = optional(set(string), [])
  }))

  default = {}

  validation {
    condition = alltrue([
      for account_name, configuration in var.securityhub_cspm_account_policies :
      trimspace(account_name) != ""
    ])

    error_message = "Security Hub CSPM policy account names cannot be empty."
  }

  validation {
    condition = alltrue([
      for account_name, configuration in var.securityhub_cspm_account_policies :
      length(setsubtract(
        configuration.enabled_standards,
        toset([
          "aws_fsbp",
          "aws_tagging",
          "cis_1_2",
          "cis_5_0",
          "nist_800_53",
          "pci_dss",
        ])
      )) == 0
    ])

    error_message = "A Security Hub CSPM policy contains an unsupported standard."
  }

  validation {
    condition = alltrue([
      for account_name, configuration in var.securityhub_cspm_account_policies :
      !configuration.associate_policy || configuration.create_policy
    ])

    error_message = "A Security Hub CSPM policy must be created before it can be associated."
  }

  validation {
    condition = alltrue([
      for account_name, configuration in var.securityhub_cspm_account_policies :
      !configuration.associate_policy || length(configuration.enabled_standards) > 0
    ])

    error_message = "Each enabled Security Hub CSPM policy must contain at least one standard."
  }
}

variable "guardduty_organization_features" {
  description = "GuardDuty protection plans centrally-managed across the AWS organization."

  type = map(object({
    auto_enable = optional(string, "ALL")

    additional_configuration = optional(map(string), {})
  }))

  default = {
    S3_DATA_EVENTS = {
      auto_enable = "ALL"
    }

    EBS_MALWARE_PROTECTION = {
      auto_enable = "ALL"
    }

    LAMBDA_NETWORK_LOGS = {
      auto_enable = "ALL"
    }

    RUNTIME_MONITORING = {
      auto_enable = "ALL"

      additional_configuration = {
        EC2_AGENT_MANAGEMENT = "ALL"
      }
    }
  }

  validation {
    condition = alltrue([
      for feature in values(var.guardduty_organization_features) :
      contains(["ALL", "NEW", "NONE"], feature.auto_enable)
    ])

    error_message = "GuardDuty organization feature auto_enable values must be ALL, NEW, or NONE."
  }

  validation {
    condition = alltrue(flatten([
      for feature in values(var.guardduty_organization_features) : [
        contains(["ALL", "NEW", "NONE"], value)
      ]
    ]))

    error_message = "GuardDuty additional confiruation values must be ALL, NEW, or NONE."
  }
}