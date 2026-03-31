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

variable "github_owner" {
  description = "GitHub organization or username (repo owner)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "github_branches" {
  description = "List of branches allowed to assume the github_oidc role"
  type        = list(string)
  default = [
    "main"
  ]
}

variable "github_allow_pull_requests" {
  description = "Allow pull_request subject in OIDC trust policy"
  type        = bool
  default     = false
}

variable "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider"
  type = string
}