variable "enable_secops_analyst_dev" {
  description = "Determines whether SecOps-Analyst resources are deployed in the 'dev' env"
  type        = bool
  default     = false
}

variable "enable_secops_analyst_prod" {
  description = "Determines whether SecOps-Analyst resources are deployed in the 'prod' env"
  type        = bool
  default     = false
}

variable "enable_secops_analyst_staging" {
  description = "Determines whether SecOps-Analyst resources are deployed in the 'staging' env"
  type        = bool
  default     = false
}

variable "enable_secops_engineer_dev" {
  description = "Determines whether SecOps-Engineer resources are deployed in the 'dev' env"
  type        = bool
  default     = false
}

variable "enable_secops_engineer_prod" {
  description = "Determines whether SecOps-Engineer resources are deployed in the 'prod' env"
  type        = bool
  default     = false
}

variable "enable_secops_engineer_staging" {
  description = "Determines whether SecOps-Engineer resources are deployed in the 'staging' env"
  type        = bool
  default     = false
}

variable "account_id_dev" {
  description = "ID of the AWS account managing the 'dev' environment"
  type        = string
}

variable "account_id_prod" {
  description = "ID of the AWS account managing the 'prod' environment"
  type        = string
}

variable "account_id_staging" {
  description = "ID of the AWS account managing the 'staging' environment"
  type        = string
}

variable "primary_region_dev" {
  description = "Primary region used by the 'dev' environment"
  type        = string
}

variable "primary_region_prod" {
  type        = string
  description = "Primary region used by the 'prod' environment"
}

variable "primary_region_staging" {
  type        = string
  description = "Primary region used by the 'staging' environment"
}

variable "logs_s3_readonly_policy_name_dev" {
  description = "'Name' attribute of the 'dev' env's logs_s3_readonly policy"
  type        = string
  default     = null
}

variable "logs_s3_readonly_policy_name_prod" {
  description = "'Name' attribute of the 'prod' env's logs_s3_readonly policy"
  type        = string
  default     = null
}

variable "logs_s3_readonly_policy_name_staging" {
  description = "'Name' attribute of the 'staging' env's logs_s3_readonly policy"
  type        = string
  default     = null
}

variable "logs_cmk_decrypt_policy_name_dev" {
  description = "'Name' attribute of the 'dev' env's logs_cmk_decrypt policy"
  type        = string
  default     = null
}

variable "logs_cmk_decrypt_policy_name_prod" {
  description = "'Name' attribute of the 'prod' env's logs_cmk_decrypt policy"
  type        = string
  default     = null
}

variable "logs_cmk_decrypt_policy_name_staging" {
  description = "'Name' attribute of the 'staging' env's logs_cmk_decrypt policy"
  type        = string
  default     = null
}