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
  description = "Map of AWS Network Firewall endpoint IDs keyed by Availability Zone; required when 'egress_mode' is 'network_firewall'."
  type        = map(string)
  default     = {}
}

variable "egress_mode" {
  description = "Private subnet egress mode. Valid values: network_firewall, nat_only, vpc_endpoints_only"
  type        = string

  validation {
    condition = contains([
      "network_firewall",
      "nat_only",
      "vpc_endpoints_only"
    ], var.egress_mode)

    error_message = "egress_mode must be one of: network_firewall, nat_only, vpc_endpoints_only."
  }
}