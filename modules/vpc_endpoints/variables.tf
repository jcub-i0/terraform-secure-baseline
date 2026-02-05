variable "vpc_id" {
  type = string
}

variable "account_id" {
  type = string
}

variable "primary_region" {
  type = string
}

# SUBNET VARIABLES
variable "compute_subnet_ids_list" {
  type = list(string)
}

variable "data_private_subnet_ids_list" {
  type = list(string)
}

variable "serverless_private_subnet_ids_list" {
  type = list(string)
}