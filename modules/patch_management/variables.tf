variable "cloud_name" {
  description = "Name of the cloud environment"
  type        = string
}

variable "patch_tag_value" {
  description = "Tag value used to target patchable instances"
  type        = string
  default     = "weekly-linux"
}

variable "patch_schedule" {
  description = "Cron-formatted schedule for patches to take place"
  type        = string
  default     = "cron(0 3 ? * SUN *)"
}

variable "schedule_timezone" {
  description = "Timezone for the scheduled patching to take place, referenced by var.patch_schedule"
  type = string
  default = "America/New_York"
}

variable "patching_enabled" {
  description = "Enabled or disable patching"
  type        = bool
  default     = true
}

variable "patch_maintenance_window_role_arn" {
  description = "ARN attribute of the Patch Maintenance Window's IAM role"
  type        = string
}