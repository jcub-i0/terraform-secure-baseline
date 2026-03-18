variable "cloud_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "cloudtrail_log_group_name" {
  type = string
}

variable "secops_emails" {
  type = list(string)
}

variable "tamper_detection_rule_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "lambda_ip_enrichment_role_arn" {
  type = string
}

variable "lambda_ec2_isolation_role_arn" {
  type = string
}

variable "lambda_ec2_rollback_role_arn" {
  type = string
}