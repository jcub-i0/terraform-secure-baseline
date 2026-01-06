variable "main_vpc_cidr" {
  description = "CIDR block for the primary VPC"
  default     = "10.0.0.0/16"
  type        = string
}

variable "data_private_subnet_cidrs" {
  description = "Map of AZ -> CIDR for Data Private Subnets"
  type        = map(string)

  default = {
    "us-east-1a" = "10.0.32.0/24"
    "us-east-1b" = "10.0.33.0/24"
  }
}