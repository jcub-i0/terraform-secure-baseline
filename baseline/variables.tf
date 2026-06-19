variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
  default     = "tf-secure-baseline"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
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

variable "cloudwatch_retention_days" {
  description = "CloudWatch log retention in days. Set to null to use the deployment_profile default."
  type        = number
  default     = null

  validation {
    condition = (
      var.cloudwatch_retention_days == null ||
      contains([
        1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180,
        365, 400, 545, 731, 1096, 1827, 2192, 2557,
        3653
      ], var.cloudwatch_retention_days)
    )

    error_message = "cloudwatch_retention_days must be null or a valid CLoudWatch Logs retention value."
  }
}

variable "primary_region" {
  description = "Primary Region used"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "ID of the AWS account where infrastructure is deployed"
  type        = string
}

variable "random_id" {
  description = "Random 4-digit string"
  type        = string
}

variable "main_vpc_cidr" {
  description = "CIDR block for the primary VPC"
  default     = "10.0.0.0/16"
  type        = string
}

variable "azs" {
  description = "List of Availability Zones for deployment. If you add/remove an AZ from var.azs, update this."
  type        = list(string)
  default = [
    "us-east-1a",
    "us-east-1b"
  ]
}

variable "subnet_cidrs" {
  description = "CIDR blocks for each subnet type. If you add/remove an AZ from var.azs, update this."
  type        = map(list(string))
  default = {
    "public"             = ["10.0.0.0/24", "10.0.1.0/24"]
    "compute_private"    = ["10.0.16.0/24", "10.0.17.0/24"]
    "data_private"       = ["10.0.32.0/24", "10.0.33.0/24"]
    "serverless_private" = ["10.0.48.0/24", "10.0.49.0/24"]
    "firewall_private"   = ["10.0.64.0/24", "10.0.65.0/24"]
    "endpoint_private"   = ["10.0.128.0/24", "10.0.129.0/24"]
  }
}

variable "db_port" {
  description = "Port used by the database (Postgres=5432, MySQL=3306)"
  type        = string
  default     = "5432"
}

variable "db_username" {
  description = "The username for the RDS database"
  type        = string
  default     = "dbadmin"
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

variable "guardduty_features" {
  description = "List of GuardDuty features that dictate what data GuardDuty analyzes"
  type        = list(string)
  default = [
    "S3_DATA_EVENTS",
    "EBS_MALWARE_PROTECTION",
    "LAMBDA_NETWORK_LOGS",
    "RUNTIME_MONITORING"
  ]
}

variable "bucket_admin_principals" {
  description = "IAM principal ARNs allowed to administer protected S3 bucket settings."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_principals) > 0
    error_message = "bucket_admin_principals must contain at least one IAM principal ARN."
  }
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

variable "enable_config" {
  description = "Whether to enable AWS Config. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "backup_enabled" {
  description = "Whether to enable AWS Backup. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "inspector_enabled" {
  description = "Whether to enable Amazon Inspector. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
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

  validation {
    condition = (
      !contains(var.inspector_resource_types, "LAMBDA_CODE")
      || contains(var.inspector_resource_types, "LAMBDA")
    )
    error_message = "inspector_resource_types cannot include LAMBDA_CODE unless LAMBDA is also included."
  }
}

variable "ip_enrichment_write_to_securityhub" {
  description = "Define whether you want the IP Enrichment Lambda function to write its enrichments to SecurityHub findings"
  type        = bool
  default     = true
}

variable "abuseipdb_api_key" {
  description = "AbuseIPDB API key for IP Enrichment Lamba"
  type        = string
  sensitive   = true
}

variable "ip_enrich_max_ips_per_event" {
  description = "The MAX_IPS_PER_EVENT environment variable for the IP Enrichment Lambda function"
  type        = string
  default     = "25"
}

variable "ip_enrich_abuseipdb_max_age" {
  description = "The ABUSEIPDB_MAX_AGE_DAYS environment variable for the IP Enrichment Lambda function"
  type        = string
  default     = "90"
}

variable "ip_enrich_max_ips_extracted" {
  description = "The MAX_IPS_EXTRACTED environment variable for the IP Enrichment Lambda function"
  type        = string
  default     = "200"
}

variable "patch_tag_value" {
  description = "Tag value used to target patchable instances (the key is 'PatchGroup' by default)"
  type        = string
  default     = "weekly-linux"
}

variable "backup_schedule" {
  description = "CRON expression for when backups are performed"
  type        = string
  default     = "cron(0 5 * * ? *)"
}

variable "delete_backups_after_days" {
  description = "Number of days to retain backups before deletion"
  type        = string
  default     = "30"
}

variable "break_glass_trusted_principal_arns" {
  description = "ARNs allowed to assume the break-glass admin role. Keep this list extremely small."
  type        = list(string)
  default     = []
}