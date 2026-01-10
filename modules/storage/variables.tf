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
  type = list(string)
}

variable "db_username" {
  type = string
}