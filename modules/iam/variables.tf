variable "cloudtrail_log_group_arn" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}

variable "logs_kms_key_arn" {
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