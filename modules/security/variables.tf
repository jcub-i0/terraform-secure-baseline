variable "primary_region" {
  type = string
}

variable "config_role_arn" {
  type = string
}

variable "centralized_logs_bucket_name" {
  type = string
}

variable "current_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "compliance_topic_arn" {
  type = string
}

variable "guardduty_features" {
  type = list(string)
}

variable "config_remediation_role_arn" {
  type = string
}

variable "secops_event_bus_name" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}