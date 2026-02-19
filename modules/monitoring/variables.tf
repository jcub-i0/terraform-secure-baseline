variable "logs_kms_key_arn" {
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