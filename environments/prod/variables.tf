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
  description = "IAM principal ARNs allowed to administer protected S3 bucket settings."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_principals) > 0
    error_message = "bucket_admin_principals must contain at least one IAM principal ARN."
  }
}

variable "abuseipdb_api_key" {
  description = "AbuseIPDB API key for IP Enrichment Lamba"
  type        = string
  sensitive   = true
  default     = null
}

variable "enable_config" {
  description = "Whether to enable AWS Config. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "enable_rules" {
  description = "Rules to be enabled in the 'config_baseline' module"
  type = object({
    s3_baseline         = bool
    cloudtrail_baseline = bool
    rds_baseline        = bool
    ebs_baseline        = bool
    sg_baseline         = bool
    iam_baseline        = bool
    ec2_baseline        = bool
    kms_baseline        = bool
  })

  default = {
    s3_baseline         = true
    cloudtrail_baseline = true
    rds_baseline        = true
    ebs_baseline        = true
    sg_baseline         = true
    iam_baseline        = false
    ec2_baseline        = true
    kms_baseline        = true
  }
}

variable "backup_enabled" {
  description = "Whether to enable AWS Backup. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "inspector_enabled" {
  description = "Whether to enable Amazon Inspector. Set to null to use the deployment_profile default."
  type = bool
  default = null
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

variable "inspector_resource_types" {
  description = "Amazon Inspector resource types to enable. Lambda scan types are disabled by default because this baseline encrypts Lambda resources with customer-managed KMS keys, which Inspector Lambda scanning does not support."
  type        = list(string)
  default     = ["EC2"]

  validation {
    condition = alltrue([
      for resource_type in var.inspector_resource_types :
      contains(["EC2", "ECR", "LAMBDA", "LAMBDA_CODE", "CODE_REPOSITORY"], resource_type)
    ])
    error_message = "inspector_resource_types must contain only EC2, ECR, LAMBDA, LAMBDA_CODE, or CODE_REPOSITORY."
  }
}