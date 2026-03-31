########################
# GITHUB OIDC VARIABLES
########################

variable "name_prefix" {
  type = string
}

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