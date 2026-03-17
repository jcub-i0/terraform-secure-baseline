variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
  default     = "tf-secure-baseline"
}

variable "environment" {
  description = "Environment name"
  type = string
  default = "dev"
}

variable "primary_region" {
  description = "Primary Region used"
  type        = string
  default     = "us-east-1"
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

variable "db_password" {
  description = "The password for the RDS database"
  type        = string
  sensitive   = true
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

variable "bucket_admin_principles" {
  description = "Principals allowed to manage the Centralized Logs Bucket guardrails (polish/versioning)"
  type        = list(string)
}

variable "enable_rules" {
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

variable "config_enabled" {
  type    = bool
  default = false
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

variable "secops_operator_trusted_principal_arns" {
  description = "Additional principals allowed to assume SecOps-Operator"
  type        = list(string)
  default     = []
}

variable "patch_tag_value" {
  description = "Tag value used to target patchable instances (the key is 'PatchGroup' by default)"
  type        = string
  default     = "weekly-linux"
}