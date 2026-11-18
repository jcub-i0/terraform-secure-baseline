variable "cloud_name" {
  description = "Cloud/platform name used in shared resource prefixes."
  type        = string
}

variable "primary_region" {
  description = "Primary AWS region for the workload."
  type        = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "account_id" {
  description = "The ID of the AWS account Terraform is using"
  type        = string
}

variable "random_id" {
  description = "Random string of characters"
  type        = string
}

variable "bucket_admin_principals" {
  type = list(string)
}

variable "centralized_logs_force_destroy" {
  description = "Whether the centralized logs bucket may delete contained objects during destruction; non-production and approved production retirement only."
  type        = bool
}
