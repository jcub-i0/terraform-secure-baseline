variable "main_vpc_cidr" {
  type = string
}

variable "data_private_subnet_cidrs" {
  type = map(string)
}