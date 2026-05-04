variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "primary_region" {
  type = string
}

variable "bucket_admin_principals" {
  description = "Principals allowed to manage bucket guardrails (policy/versioning)"
  type        = list(string)
}