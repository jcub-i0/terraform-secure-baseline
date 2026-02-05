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
variable "compute_private_subnet_ids_map" {
  type = map(string)
}

variable "serverless_private_subnet_ids_map" {
  type = map(string)
}

variable "subnet_cidrs" {
  type = map(list(string))
}