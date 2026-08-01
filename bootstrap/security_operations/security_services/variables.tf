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