variable "cloud_name" {
    description = "Name of the cloud environment"
  type = string
}

variable "patch_tag_value" {
  description = "Tag value used to target patchable instances"
  type = string
  default = "weekly-linux"
}