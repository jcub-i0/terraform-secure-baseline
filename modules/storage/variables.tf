variable "vpc_id" {
  type = string
}

variable "db_port" {
  type = string
}

variable "compute_sg_id" {
  type = string
}

variable "data_private_subnet_ids_list" {
  description = "list(string) of Data Private Subnet IDs"
  type        = list(string)
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "logs_kms_key_arn" {
  type = string
}

variable "account_id" {
  description = "The ID of the AWS account Terraform is using"
  type        = string
}

variable "random_id" {
  description = "Random string of characters"
  type        = string
}

variable "cloudtrail_arn" {
  type = string
}

variable "bucket_admin_principals" {
  type = list(string)
}