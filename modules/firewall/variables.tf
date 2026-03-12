variable "cloud_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "firewall_private_subnet_ids_map" {
  type = map(string)
}

variable "logs_cmk_arn" {
  type = string
}

variable "network_firewall_log_group_name" {
  type    = string
  default = "/aws/firewall/egress"
}

variable "centralized_logs_bucket_arn" {
  type = string
}

variable "centralized_logs_bucket_name" {
  type = string
}