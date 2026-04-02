########################
# GITHUB OIDC VARIABLES
########################

variable "name_prefix" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "owner_github" {
  description = "GitHub organization or username (repo owner)"
  type        = string
}

variable "repo_github" {
  description = "GitHub repository name"
  type        = string
}

variable "branches_github" {
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
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider"
  type        = string
}

variable "tf_state_lock_table_arn" {
  description = "ARN of the DynamoDB table used for Terraform state locking"
  type        = string
  default     = null
}

variable "secrets_manager_cmk_arn" {
  description = "ARN of the CMK used by Secrets Manager"
  type        = string
}