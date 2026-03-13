variable "alert_topic_arn" {
  description = "SNS topic ARN to receive tamper alerts"
  type        = string
}

variable "cloud_name" {
  description = "Prefix used for naming EventBridge rules"
  type        = string
  default     = "tf-secure-baseline"
}