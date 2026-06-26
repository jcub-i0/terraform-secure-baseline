variable "cloud_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "config_role_arn" {
  type = string
}

variable "centralized_logs_bucket_name" {
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

variable "enable_config" {
  type = bool
}

variable "enable_rules" {
  type = object({
    s3_baseline         = bool
    cloudtrail_baseline = bool
    rds_baseline        = bool
    ebs_baseline        = bool
    sg_baseline         = bool
    iam_baseline        = bool
    ec2_baseline        = bool
    kms_baseline        = bool
  })

  default = {
    s3_baseline         = true
    cloudtrail_baseline = true
    rds_baseline        = true
    ebs_baseline        = true
    sg_baseline         = true
    iam_baseline        = false
    ec2_baseline        = true
    kms_baseline        = true
  }
}

variable "inspector_enabled" {
  type = bool
}

variable "inspector_resource_types" {
  description = "Amazon Inspector resource types to enable. Lambda scan types are disabled by default because this baseline encrypts Lambda resources with customer-managed KMS keys, which Inspector Lambda scanning does not support."
  type        = list(string)
  default     = ["EC2"]

  validation {
    condition = alltrue([
      for resource_type in var.inspector_resource_types :
      contains(["EC2", "ECR", "LAMBDA", "LAMBDA_CODE", "CODE_REPOSITORY"], resource_type)
    ])
    error_message = "inspector_resource_types must contain only EC2, ECR, LAMBDA, LAMBDA_CODE, or CODE_REPOSITORY."
  }
}

variable "sec_notifs_eventbridge_dlq_arn" {
  description = "ARN of the 'security_notifications_eventbridge_dlq' DLQ"
  type = string
}