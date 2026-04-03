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

variable "owner_github" {
  description = "GitHub organization or username (repo owner)"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_github_oidc || var.owner_github != null
    error_message = "'owner_github' must be set when 'enable_github_oidc' is 'true'."
  }
}

variable "repo_github" {
  description = "GitHub repository name"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_github_oidc || var.repo_github != null
    error_message = "'repo_github' must be set when 'enable_github_oidc' is 'true'."
  }
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

variable "lambda_cmk_arn" {
  description = "ARN of the CMK used to encrypt Lambda functions"
  type        = string
}

variable "branches_plan_github" {
  description = "List of branches allowed to assume the github_oidc role"
  type        = list(string)
  default     = ["main"]
}

variable "allow_pull_requests_plan_github" {
  description = "Allow pull_request subject in OIDC trust policy"
  type        = bool
  default     = false
}

# GitHub-Apply Role-related variables
variable "enable_apply_role_github" {
  description = "Enable the GitHub-Apply role"
  type        = bool
  default     = false
}

variable "branches_apply_github" {
  description = "Branches allowed to assume the GitHub-Apply role"
  type        = list(string)
  default     = ["main"]
}

variable "environment_apply_github" {
  description = "GitHub environment allowed to assume the GitHub-Apply role"
  type        = string
  default     = null
}

