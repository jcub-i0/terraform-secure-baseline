variable "main_vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "subnet_cidrs" {
  type = map(list(string))
}