variable "name_prefix" {
  type = string
}

variable "backup_enabled" {
  type = bool
}

variable "backup_schedule" {
  type = string
}

variable "backup_vault_cmk_arn" {
  type = string
}

variable "environment" {
  type = string
}

variable "delete_backups_after_days" {
  description = "Number of days to retain backups before deletion"
  type        = string
}

variable "backup_tag_key" {
  description = "Tag key used to select resources for backup"
  type = string
  default = "Backup"
}

variable "backup_tag_value" {
  description = "Tag value used to select resources for backup"
  type = string
  default = "true"
}