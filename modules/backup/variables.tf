variable "name_prefix" {
  type = string
}

variable "backup_enabled" {
  description = "Whether to create the AWS Backup plan and backup selection"
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

variable "force_destroy" {
  description = "Whether recovery points may be automatically deleted so the Backup vault can be destroyed"
  type        = bool
}

variable "restore_testing_enabled" {
  description = "Whether AWS Backup Restore Testing is enabled"
  type        = bool
}

variable "restore_testing_schedule" {
  description = "Schedule expression for the AWS Backup Restore Testing plan"
  type        = string
}

variable "restore_testing_start_window_hours" {
  description = "Number of hours AWS Backup may start a scheduled restore test after its scheduled time"
  type        = number
}

variable "restore_testing_selection_window_days" {
  description = "Number of days of recovery points eligible for Restore Testing"
  type        = number
}

variable "restore_testing_validation_window_hours" {
  description = "Number of hours the restored RDS resource remains available for validation"
  type        = number
}

variable "restore_testing_rds_arn" {
  description = "ARN of the Terraform-managed RDS instance selected for Restore Testing"
  type        = string
}

variable "restore_testing_db_subnet_group_name" {
  description = "DB subnet group used when restoring the RDS test resource"
  type        = string
}

variable "restore_testing_vpc_security_group_ids" {
  description = "VPC security group IDs assigned to the restored RDS test resource"
  type        = list(string)
}