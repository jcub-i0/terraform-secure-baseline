variable "cloud_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "cloudtrail_log_group_arn" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "secrets_manager_cmk_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "centralized_logs_bucket_arn" {
  type = string
}

variable "flowlogs_firehose_delivery_stream_arn" {
  type = string
}

variable "flowlogs_log_group_arn" {
  type = string
}

variable "secops_event_bus_arn" {
  type = string
}

variable "threat_intel_api_keys_arn" {
  type = string
}

variable "lambda_ip_enrichment_log_group_arn" {
  type = string
}

variable "break_glass_trusted_principal_arns" {
  type = list(string)
}

########################
# GITHUB OIDC VARIABLES
########################

variable "enable_github_oidc" {
  description = "Enable GitHub OIDC federation resources for CI/CD"
  type        = bool
  default     = false
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider"
  type        = string
  default     = null
}

variable "github_owner" {
  description = "GitHub organization or username (repo owner)"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_github_oidc || var.github_owner != null
    error_message = "'github_owner' must be set when 'enable_github_oidc' is 'true'."
  }
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_github_oidc || var.github_repo != null
    error_message = "'github_repo' must be set when 'enable_github_oidc' is 'true'."
  }
}

variable "github_branches" {
  description = "List of branches allowed to assume the github_oidc role"
  type        = list(string)
  default     = ["main"]
}

variable "github_allow_pull_requests" {
  description = "Allow pull_request subject in OIDC trust policy"
  type        = bool
  default     = false
}

variable "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_github_oidc || var.tf_state_bucket_arn != null
    error_message = "'tf_state_bucket_arn' must be set when 'enable_github_oidc' is 'true'."
  }
}

variable "tf_state_lock_table_arn" {
  description = "ARN of the DynamoDB table used for Terraform state locking"
  type        = string
  default     = null
}