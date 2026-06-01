variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "primary_region" {
  type = string
}

variable "bucket_admin_principals" {
  description = "IAM principal ARNs allowed to administer protected S3 bucket settings."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_principals) > 0
    error_message = "bucket_admin_principals must contain at least one IAM principal ARN."
  }
}