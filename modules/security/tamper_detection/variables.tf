variable "environment" {
  description = "Environment name"
  type        = string
}

variable "name_prefix" {
  type = string
}

variable "secops_topic_arn" {
  description = "SNS topic ARN to receive tamper alerts"
  type        = string
}

variable "sec_notifs_eventbridge_dlq_arn" {
  description = "ARN of the 'security_notifications_eventbridge_dlq' DLQ"
  type        = string
}

variable "cloud_name" {
  description = "Prefix used for naming EventBridge rules"
  type        = string
}