variable "name_prefix" {
  type = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "account_id" {
  description = "The ID of the AWS account Terraform is using"
  type        = string
}

variable "primary_region" {
  description = "Primary AWS region for the workload."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "worker_subnet_ids" {
  type = list(string)
}

variable "restore_test_db_sg_id" {
  type = string
}

variable "interface_endpoints_sg_id" {
  description = "Security group ID shared by the Interface VPC Endpoints"
  type        = string
}

variable "restore_testing_plan_arn" {
  type = string
}

variable "source_rds_arn" {
  type = string
}

variable "restore_validation_secret_arn" {
  type = string
}

variable "secrets_manager_cmk_arn" {
  type = string
}

variable "lambda_cmk_arn" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "log_retention_days" {
  type = number
}

variable "db_name" {
  type = string
}

variable "db_port" {
  type = number
}

variable "secops_topic_arn" {
  type = string
}