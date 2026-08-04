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

variable "enable_securityhub_dev_configuration_policy" {
  description = "Create the central Security Hub CSPM configuration policy for the dev account"
  type        = bool
  default     = false
}

variable "securityhub_cspm_account_policies" {
  description = "Per-account Security Hub CSPM central configuration policies and associations"

  type = map(object({
    create_policy                = optional(bool, false)
    associate_policy             = optional(bool, false)
    enabled_standards        = optional(set(string), ["aws_fsbp", "cis_5_0"])
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
      length(setsubstract(
        configuration.enabled_standard_keys,
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

    error_message = "A Security Hub CSPM policy contains an unsupported standard key."
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
      !configuration.associate_policy || length(configuration.enabled_standard_keys) > 0
    ])

    error_message = "Each enabled Security Hub CSPM policy must contain at least one standard."
  }
}

variable "securityhub_enabled_standard_keys_dev" {
  description = "Security Hub CSPM standards enabled by the dev configuration policy"
  type        = set(string)

  default = [
    "aws_fsbp",
    "cis_5_0"
  ]

  validation {
    condition = length(setsubtract(
      var.securityhub_enabled_standard_keys_dev,
      toset([
        "aws_fsbp",
        "aws_tagging",
        "cis_1_2",
        "cis_5_0",
        "nist_800_53",
        "pci_dss",
      ])
    )) == 0

    error_message = "securityhub_enabled_standard_keys_dev contains an unsupported standard key."
  }
}

variable "securityhub_disabled_control_identifiers_dev" {
  description = "Security Hub controls disabled by the dev configuration policy"
  type        = set(string)
  default     = []
}

variable "enable_securityhub_dev_configuration_policy_association" {
  description = "Associate the dev account with its central Security Hub CSPM configuration policy"
  type        = bool
  default     = false
}

variable "dev_account_name" {
  description = "Name of the AWS Organizations account used for the dev workload"
  type        = string
  default     = "dev"

  validation {
    condition     = trimspace(var.dev_account_name) != ""
    error_message = "dev_account_name cannot be empty."
  }
}