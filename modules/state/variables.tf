variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
  default     = "tf-secure-baseline"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  type = string
}