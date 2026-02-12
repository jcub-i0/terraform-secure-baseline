variable "vpc_id" {
  type = string
}

variable "compute_private_subnet_ids_map" {
  description = "map(string) of Compute Private Subnet IDs (az => subnet.id)"
  type        = map(string)
}

variable "instance_profile_name" {
  type = string
}

variable "ebs_kms_key_arn" {
  type = string
}

variable "interface_endpoints_sg_id" {
  type = string
}

variable "data_sg_id" {
  type = string
}

variable "db_port" {
  type = string
}