variable "name_prefix" {
  description = "Baseline naming prefix used to construct the ECS cluster name"
  type        = string
}

variable "environment" {
  description = "Workload environment identity used for ECS cluster tagging"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs used by the Internet-facing Application Load Balancer"
  type        = set(string)
}

variable "certificate_arn" {
  description = "ACM certificate ARN used by the HTTPS listener"
  type        = string
}

variable "ingress_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach teh HTTPS listener"
  type        = set(string)
}

variable "ssl_policy" {
  description = "TLS security policy used by the HTTPS listener"
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}