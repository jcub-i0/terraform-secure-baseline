variable "secops_analyst_group_name" {
  description = "Name of the SecOps-Analyst IAM group"
  type        = string
}

variable "secops_engineer_group_name" {
  description = "Name of the SecOps-Engineer IAM group"
  type        = string
}

variable "secops_operator_group_name" {
  description = "Name of the SecOps-Operator IAM group"
  type        = string
}

variable "account_id" {
  description = ""
  type        = string
}

variable "logs_s3_readonly_policy_name" {
    description = "'Name' attribute of the logs_s3_readonly policy"
  type = string
}

variable "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the logs_cmk_decrypt policy"
  type = string
}

variable "secops_rollback_trigger_policy_name" {
  description = "'Name' attribute of the secops_rollback_trigger policy"
  type = string
}