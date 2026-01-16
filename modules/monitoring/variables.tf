variable "logs_kms_key_arn" {
  type = string
}

variable "cloudtrail_log_group_name" {
  type = string
}

variable "security_emails" {
  type = list(string)
}