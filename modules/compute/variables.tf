variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "compute_private_subnet_ids_map" {
  description = "map(string) of Compute Private Subnet IDs (az => subnet.id)"
  type        = map(string)
}

variable "instance_profile_name" {
  type = string
}

variable "ebs_cmk_arn" {
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

variable "patch_tag_value" {
  type = string
}

variable "isolation_allowed" {
  description = "Whether EC2 instances may be automatically isolated by the incident-response Lambda"
  type        = bool
  default     = false
}

variable "compute_sg_rule_ids" {
  description = "Security Group rule IDs that must exist before compute EC2 instances launch"
  type = object({
    endpoints_ingress_from_compute    = string
    compute_egress_to_endpoints       = string
    compute_egress_to_db              = string
    compute_egress_to_internet_egress = optional(string)
  })
}