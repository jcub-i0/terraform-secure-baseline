variable "enable_rules" {
  type = object({
    s3_baseline         = bool
    cloudtrail_baseline = bool
    rds_baseline        = bool
    ebs_baseline        = bool
    sg_baseline         = bool
    iam_baseline        = bool
    ec2_baseline        = bool
  })

  default = {
    s3_baseline         = true
    cloudtrail_baseline = true
    rds_baseline        = true
    ebs_baseline        = true
    sg_baseline         = true
    iam_baseline        = false
    ec2_baseline        = true
  }
}

variable "config_rule_name_prefix" {
  description = "Prefix for AWS Config rule names"
  type        = string
  default     = "tf-secure-baseline"
}

variable "tags" {
  description = "Tags to apply to Config rules"
  type        = map(string)
  default = {
    "Terraform" = "true"
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