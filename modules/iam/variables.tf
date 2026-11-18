variable "cloud_name" {
  type = string
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
  type = string
}

variable "primary_region" {
  type = string
}

variable "centralized_logs_bucket_arn" {
  type = string
}

variable "break_glass_trusted_principal_arns" {
  type = list(string)
}

variable "alb_access_logs_bucket_arn" {
  description = "Optional ALB access-log bucket ARN for the shared read-only logs policy"
  type        = string
  default     = null
}
