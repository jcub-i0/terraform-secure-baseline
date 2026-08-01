variable "enable_securityhub_delegated_administrator" {
  description = "Enable Security Hub trusted access and designate the security-operations account as administrator"
  type        = bool
  default     = false
}

variable "security_operations_account_name" {
  description = "Name of the AWS Organizations account used for centralized security operations"
  type        = string
  default     = "security-operations"
}