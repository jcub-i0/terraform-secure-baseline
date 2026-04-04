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