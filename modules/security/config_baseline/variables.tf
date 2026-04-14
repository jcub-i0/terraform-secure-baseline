variable "cloud_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "config_enabled" {
  type    = bool
  default = false
}

variable "enable_rules" {
  description = "Rules to be enabled in the 'config_baseline' module"
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

variable "logs_cmk_arn" {
  type = string
}