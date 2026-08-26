variable "name_prefix" {
  description = "Baseline naming prefix used to construct ECS service resources."
  type        = string
}

variable "environment" {
  description = "Workload environment identity used for tagging."
  type        = string
}

variable "primary_region" {
  description = "AWS Region in which ECS services and CloudWatch logs are created."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID used by ECS task security groups."
  type        = string
}
variable "cluster_arn" {
  description = "ARN of the ECS cluster that hosts the services."
  type        = string
}

variable "compute_private_subnet_ids" {
  description = "Compute-private subnet IDs used by Fargate tasks."
  type        = set(string)
}

variable "cloudwatch_retention_days" {
  description = "CloudWatch Logs retention period for ECS service log groups."
  type        = number
}

variable "platform_version" {
  description = "AWS Fargate platform version used by ECS services."
  type        = string
  default     = "1.4.0"
}

variable "services" {
  description = "ECS/Fargate services keyed by stable service name"

  type = map(object({
    image = string
    container_port = number
    cpu = number
    memory = number
    desired_count = optional(number, 1)

    execution_role_arn = string
    task_role_arn = string

    target_group_arn = optional(string)

    cpu_architecture = optional(string, "X86_64")

    environment = optional(map(string), {})
  }))

  default = {}
}