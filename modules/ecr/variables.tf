variable "name_prefix" {
  description = "Baseline naming prefix used to construct ECR repository names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", var.name_prefix))
    error_message = "name_prefix must use lowercase letters and numbers separated only by periods, underscores, or hyphens."
  }
}

variable "environment" {
  description = "Workload environment identity used for repository tagging."
  type        = string

  validation {
    condition     = length(trimspace(var.environment)) > 0 && var.environment == trimspace(var.environment)
    error_message = "environment must be a non-empty value without leading or trailing whitespace."
  }
}

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key used to encrypt ECR repositories."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov|aws-cn):kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a customer-managed KMS key ARN."
  }
}

variable "repositories" {
  description = "Private ECR repositories keyed by repository name."
  type        = map(object({}))
  default     = {}

  validation {
    condition = alltrue([
      for repository_name in keys(var.repositories) :
      can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", repository_name))
    ])

    error_message = "Repository names must use lowercase ECR repository-name syntax."
  }
}

variable "ecs_security_policy_services" {
  description = "ECS service security-policy inputs keyed by service name"

  type = map(object({
    task_sg_id     = string
    container_port = number

    alb_sg_id       = optional(string)
    database_access = optional(bool, false)
  }))

  default = {}
}

variable "s3_prefix_list_id" {
  description = "AWS-managed S3 prefix list ID used for private S3 access"
  type = string
  default = null

  validation {
    condition = (
      length(var.ecs_security_policy_services) == 0 ||
      var.s3_prefix_list_id != null
    )

    error_message = "s3_prefix_list_id must be provided when ECS security-policy services are configured."
  }
}