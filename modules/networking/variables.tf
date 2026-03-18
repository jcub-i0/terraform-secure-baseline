variable "name_prefix" {
  type = string
}

variable "main_vpc_cidr" {
  type = string
}

variable "environment" {
  type = string
}

variable "cloud_name" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "subnet_cidrs" {
  type = map(list(string))
}

variable "firewall_endpoint_ids_by_az" {
  type = map(string)
}