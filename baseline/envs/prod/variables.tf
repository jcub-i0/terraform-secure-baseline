variable "cloud_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "bucket_admin_principals" {
  type = list(string)
}

variable "abuseipdb_api_key" {
  type      = string
  sensitive = true
}

variable "config_enabled" {
  type = bool
}