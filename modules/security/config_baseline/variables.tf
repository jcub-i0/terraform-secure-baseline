variable "enable_rules" {
  type = object({
    s3_baseline         = bool
    cloudtrail_baseline = bool
    rds_baseline        = bool
    ebs_baseline        = bool
    sg_baseline         = bool
    iam_baseline        = bool
  })

  default = {
    s3_baseline         = true
    cloudtrail_baseline = true
    rds_baseline        = true
    ebs_baseline        = true
    sg_baseline         = true
    iam_baseline        = false
  }
}

variable "config_role_arn" {
  type = string
}

variable "centralized_logs_bucket_name" {
  type = string
}

variable "compliance_topic_arn" {
  type = string
}

variable "config_remediation_role_arn" {
  type = string
}

variable "logs_kms_key_arn" {
  type = string
}