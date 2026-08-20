variable "cloud_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
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

variable "cloudwatch_retention_days" {
  type = string
}

variable "network_firewall_log_group_name" {
  type    = string
  default = "/aws/firewall/egress"
}

variable "allowed_egress_domains" {
  description = "Environment-approved application egress domains added to the platform-required Network Firewall allowlist. Use exact domains or an initial dot for AWS Network Firewall suffix matching."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for domain in var.allowed_egress_domains :
      length(domain) > 0 &&
      domain == trimspace(domain) &&
      length(regexall("\\s", domain)) == 0 &&
      !strcontains(domain, "://") &&
      !strcontains(domain, "/") &&
      !strcontains(domain, "?") &&
      !strcontains(domain, "#") &&
      !strcontains(domain, "@") &&
      !strcontains(domain, ":") &&
      !strcontains(domain, "*") &&
      !strcontains(domain, "..") &&
      trim(domain, ".") != "" &&
      length(regexall("^\\.?[0-9]+(\\.[0-9]+){3}\\.?$", domain)) == 0
    ])

    error_message = "allowed_egress_domains entries must be exact domains or initial-dot suffix domains, not empty values, URLs, paths, wildcard expressions, IP addresses, or CIDRs."
  }
}

variable "centralized_logs_bucket_arn" {
  type = string
}

variable "centralized_logs_bucket_name" {
  type = string
}
