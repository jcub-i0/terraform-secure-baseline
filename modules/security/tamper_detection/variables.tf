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

variable "cloud_name" {
  description = "Prefix used for naming EventBridge rules"
  type        = string
}