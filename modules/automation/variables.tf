variable "vpc_id" {
  type = string
}

variable "lambda_ec2_isolation_role_arn" {
  type = string
}

variable "lambda_ec2_rollback_role_arn" {
  type = string
}

variable "serverless_private_subnet_ids" {
  type = list(string)
}

variable "quarantine_sg_id" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "secops_role_arn" {
  type = string
}

variable "primary_region" {
  type = string
}