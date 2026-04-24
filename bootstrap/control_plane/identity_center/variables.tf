variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "dev_account_id" {
  description = "ID of the AWS account managing the 'dev' environment"
  type        = string
}

variable "prod_account_id" {
  description = "ID of the AWS account managing the 'prod' environment"
  type        = string
}

variable "staging_account_id" {
  description = "ID of the AWS account managing the 'staging' environment"
  type        = string
}

variable "dev_primary_region" {
  description = "Primary region used by the 'dev' environment"
  type        = string
}

variable "prod_primary_region" {
  type        = string
  description = "Primary region used by the 'prod' environment"
}

variable "staging_primary_region" {
  type        = string
  description = "Primary region used by the 'staging' environment"
}

variable "secops_analyst_group_name" {
  description = "Name of the SecOps-Analyst IAM group"
  type        = string
  default     = null
}

variable "secops_engineer_group_name" {
  description = "Name of the SecOps-Engineer IAM group"
  type        = string
  default     = null
}

variable "account_id" {
  description = "ID of the AWS account managing this environment"
  type        = string
}

variable "customer_managed_policy_path" {
  description = "Path of customer managed IAM policies used by permission sets"
  type        = string
  default     = "/"
}

variable "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the logs_s3_readonly policy"
  type        = string
  default     = null
}

variable "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the logs_cmk_decrypt policy"
  type        = string
  default     = null
}

variable "secops_event_bus_arn" {
  description = "ARN of the SecOps Event Bus"
  type        = string
}