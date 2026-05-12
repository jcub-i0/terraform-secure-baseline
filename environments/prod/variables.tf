variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "deployment_profile" {
  description = "Deployment profile controlling cost/security defaults. Valid values: production, development, minimal."
  type        = string
  default     = "production"

  validation {
    condition = contains([
      "production",
      "development",
      "minimal"
    ], var.deployment_profile)

    error_message = "deployment_profile must be one of: production, development, minimal."
  }
}

variable "egress_mode" {
  description = "Private subnet egress mode. Valid values: network_firewall, nat_only, vpc_endpoints_only, or auto."
  type        = string
  default     = "auto"

  validation {
    condition = contains([
      "auto",
      "network_firewall",
      "nat_only",
      "vpc_endpoints_only"
    ], var.egress_mode)

    error_message = "egress_mode must be one of: auto, network_firewall, nat_only, vpc_endpoints_only."
  }
}

variable "primary_region" {
  description = "Primary Region used"
  type        = string
}

variable "bucket_admin_principals" {
  description = "Principals allowed to manage bucket guardrails (policy/versioning)"
  type        = list(string)
  default     = []
}

variable "abuseipdb_api_key" {
  description = "AbuseIPDB API key for IP Enrichment Lamba"
  type        = string
  sensitive   = true
  default     = null
}

variable "config_enabled" {
  description = "Define whether AWS Config is enabled or not"
  type        = bool
}

variable "backup_enabled" {
  description = "Define whether backup resources are enabled"
  type        = bool
}

variable "break_glass_trusted_principal_arns" {
  description = "ARNs allowed to assume the break-glass admin role. Keep this list extremely small."
  type        = list(string)
  default     = []
}

variable "secops_emails" {
  description = "List of emails to send security-related notifications to"
  type        = list(string)
  default     = []

  # VALIDATE EMAIL FORMATS
  validation {
    condition     = alltrue([for e in var.secops_emails : can(regex("^.+@.+\\..+$", e))])
    error_message = "Each entry in secops_emails must be a valid email address."
  }
}