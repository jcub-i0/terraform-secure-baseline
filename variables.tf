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
  description = "List of Availability Zones for deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "subnet_cidrs" {
  description = "CIDR blocks for each subnet type"
  type        = map(list(string))
  default = {
    "public"             = ["10.0.0.0/24", "10.0.1.0/24"]
    "compute_private"    = ["10.0.16.0/24", "10.0.17.0/24"]
    "data_private"       = ["10.0.32.0/24", "10.0.33.0/24"]
    "serverless_private" = ["10.0.48.0/24", "10.0.49.0/24"]
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