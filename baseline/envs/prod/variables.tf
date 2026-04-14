variable "cloud_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "bucket_admin_principals" {
  description = "Principals allowed to manage bucket guardrails (polish/versioning)"
  type = list(string)
}

variable "abuseipdb_api_key" {
  type      = string
  sensitive = true
}

variable "config_enabled" {
  type = bool
}

variable "backup_enabled" {
  description = "Define whether backup resources are enabled"
  type        = bool
}

variable "break_glass_trusted_principal_arns" {
  description = "ARNs allowed to assume the break-glass admin role. Keep this list extremely small."
  type        = list(string)
}

variable "secops_emails" {
  description = "List of emails to send security-related notifications to"
  type        = list(string)

  # VALIDATE EMAIL FORMATS
  validation {
    condition     = alltrue([for e in var.secops_emails : can(regex("^.+@.+\\..+$", e))])
    error_message = "Each entry in secops_emails must be a valid email address."
  }
}