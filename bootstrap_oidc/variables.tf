########################
# GITHUB OIDC VARIABLES
########################

variable "enable_github_oidc" {
  description = "Enable GitHub OIDC federation resources for CI/CD"
  type        = bool
  default     = false
}

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

variable "primary_region" {
  description = "Primary Region used"
  type        = string
  default     = "us-east-1"
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
}

variable "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  type        = string
}

variable "tf_state_bucket_cmk_arn" {
  description = "ARN of the KMS CMK used to encrypt the Terraform State bucket"
  type        = string
  default     = null
}

variable "tf_state_lock_table_arn" {
  description = "ARN of the DynamoDB table used for Terraform state locking"
  type        = string
  default     = null
}

# GitHub-Plan role-related variables
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