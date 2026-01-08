variable "primary_region" {
  description = "Primary Region used"
  type = string
  default = "us-east-1"
}

variable "main_vpc_cidr" {
  description = "CIDR block for the primary VPC"
  default     = "10.0.0.0/16"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "Map of AZ -> CIDR for Public Subnets"
  type        = map(string)

  default = {
    "us-east-1a" = "10.0.0.0/24"
    "us-east-1b" = "10.0.1.0/24"
  }
}

variable "compute_private_subnet_cidrs" {
  description = "Map of AZ -> CIDR for Compute Private Subnets"
  type        = map(string)

  default = {
    "us-east-1a" = "10.0.16.0/24"
    "us-east-1b" = "10.0.17.0/24"
  }
}

variable "data_private_subnet_cidrs" {
  description = "Map of AZ -> CIDR for Data Private Subnets"
  type        = map(string)

  default = {
    "us-east-1a" = "10.0.32.0/24"
    "us-east-1b" = "10.0.33.0/24"
  }
}

variable "serverless_private_subnet_cidrs" {
  description = "Map of AZ -> CIDR for Serverless Private Subnets"
  type        = map(string)

  default = {
    "us-east-1a" = "10.0.48.0/24"
    "us-east-1b" = "10.0.49.0/24"
  }
}