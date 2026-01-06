variable "main_vpc_cidr" {
  type = string
}

variable "public_subnet_cidrs" {
  type = map(string)
}

variable "compute_private_subnet_cidrs" {
  type = map(string)
}

variable "data_private_subnet_cidrs" {
  type = map(string)
}

variable "serverless_private_subnet_cidrs" {
  type = map(string)
}