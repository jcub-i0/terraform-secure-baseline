variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "cloud_name" {
  type = string
}

variable "centralized_logs_bucket_id" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "cloudwatch_retention_days" {
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
