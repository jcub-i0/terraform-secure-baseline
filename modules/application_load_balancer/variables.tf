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