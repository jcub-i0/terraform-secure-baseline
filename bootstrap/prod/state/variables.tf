variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "state_region" {
  description = "AWS Region hosting the Terraform state bucket and KMS key."
  type        = string
  default     = "us-east-1"
  nullable    = false
}

variable "bucket_admin_principals" {
  description = "IAM principal ARNs allowed to administer protected S3 bucket settings."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_principals) > 0
    error_message = "bucket_admin_principals must contain at least one IAM principal ARN."
  }
}

variable "application_state_backends" {
  description = "Application backends administered by this bootstrap stack; empty creates none."
  type = map(object({
    bucket_name = string
    access = object({
      plan_role_arn           = string
      apply_role_arn          = string
      administrator_role_arns = set(string)
    })
  }))
  default  = {}
  nullable = false

  validation {
    condition = length(distinct([
      for backend in values(var.application_state_backends) : backend.bucket_name
    ])) == length(var.application_state_backends)
    error_message = "Each application must have its own backend bucket."
  }
}