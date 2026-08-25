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

variable "services" {
  description = "ALB target groups and HTTPS routing rules keyed by ECS service name"

  type = map(object({
    container_port = number
    priority = number
    host_headers = optional(set(string), [])
    path_patterns = optional(set(string), [])
    health_check_path = optional(string, "/health")
  }))

  default = {}

  validation {
    condition = alltrue([
        for service in values(var.services) :
        service.container_port >= 1 && service.container_port <= 65535
    ])

    error_message = "Each service container_port must be between 1 and 65535."
  }

  validation {
    condition = alltrue([
        for service in values(var.services) :
        service.priority >= 1 && service.priority <= 50000
    ])

    error_message = "Each service listener-rule priority must be between 1 and 50000."
  }

  validation {
    condition = length(distinct([
        for service in values(var.services) : service.priority
    ])) == length(var.services)

    error_message = "Each service must use a unique listener-rule priority."
  }

  validation {
    condition = alltrue([
        for service in values(var.services) :
        length(service.host_headers) > 0 || length(service.path_patterns) > 0
    ])

    error_message = "Each ALB service msut define at least one host_headers or path_patterns routing condition."
  }
}