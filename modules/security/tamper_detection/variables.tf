variable "alert_topic_arn" {
  description = "SNS topic ARN to receive tamper alerts"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for naming EventBridge rules"
  type        = string
  default     = "tf-secure-baseline"
}