variable "vpc_id" {
  type = string
}

variable "centralized_logs_bucket_id" {
  type = string
}

variable "logs_kms_key_arn" {
  type = string
}

variable "cloudtrail_role_arn" {
  type = string
}

variable "flowlogs_role_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}

variable "firehose_flow_logs_role_arn" {
  type = string
}

variable "centralized_logs_bucket_arn" {
  type = string
}