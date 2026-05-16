variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

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
variable "endpoint_private_subnet_ids_map" {
  type = map(string)
}

variable "compute_private_subnet_ids_map" {
  type = map(string)
}

variable "serverless_private_subnet_ids_map" {
  type = map(string)
}

variable "subnet_cidrs" {
  type = map(list(string))
}

variable "compute_sg_id" {
  type = string
}

variable "lambda_ec2_isolation_sg_id" {
  type = string
}

variable "lambda_ec2_rollback_sg_id" {
  type = string
}

variable "endpoint_private_rt_ids_map" {
  description = "map(string) of Endpoint Private Route Table IDs"
  type        = map(string)
}

variable "s3_gateway_endpoint_rt_ids_list" {
  description = "Route table IDs that should use the S3 Gateway VPC Endpoint"
  type = list(string)
}