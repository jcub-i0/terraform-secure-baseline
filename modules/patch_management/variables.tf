variable "cloud_name" {
  description = "Name of the cloud environment"
  type        = string
}

variable "patch_tag_value" {
  description = "Tag value used to target patchable instances"
  type        = string
  default     = "weekly-linux"
}

variable "patching_enabled" {
  description = "Enabled or disable patching"
  type        = bool
  default     = true
}

variable "patch_maintenance_window_role_arn" {
  description = "ARN attribute of the Patch Maintenance Window's IAM role"
  type = string
}