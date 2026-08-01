variable "security_operations_account_id" {
  description = "AWS account ID designated as the centralized security-services administrator"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.security_operations_account_id))
    error_message = "security_operations_account_id must be a 12-digit AWS account ID."
  }
}

variable "enable_securityhub_delegated_administrator" {
  description = "Enable Security Hub trusted accerss and designate the security-operations account as administrator"
  type = bool
  default = false
}