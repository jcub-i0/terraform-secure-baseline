variable "name_prefix" {
  description = "Baseline naming prefix used to construct the ECS cluster name"
  type = string
}

variable "environment" {
  description = "Workload environment identity used for ECS cluster tagging"
  type = string
}

variable "container_insights" {
  description = "CloudWatch Container Insights mode for the ECS cluster"
  type = string
  default = "enhanced"

  validation {
    condition = contains([
        "enhanced",
        "enabled",
        "disabled",
    ], var.container_insights)

    error_message = "container_insights must be enhanced, enabled, or disabled."
  }
}