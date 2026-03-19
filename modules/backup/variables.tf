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