variable "name_prefix" {
  type = string
}

variable "backup_enabled" {
  description = "Whether to create the AWS Backup plan and backup selection."
  type        = bool
}

variable "backup_schedule" {
  description = "AWS Backup schedule expression used by the backup plan when backups are enabled"
  type        = string
}

variable "delete_backups_after_days" {
  description = "Number of days to retain AWS Backup recovery points before deletion when backups are enabled"
  type        = number
}

variable "backup_vault_cmk_arn" {
  type = string
}

variable "environment" {
  type = string
}

variable "backup_service_role_arn" {
  description = "IAM role ARN used by AWS Backup for resource backups"
  type        = string
}

variable "backup_tag_key" {
  description = "Tag key used to select resources for backup"
  type        = string
  default     = "Backup"
}