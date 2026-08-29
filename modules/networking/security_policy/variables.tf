variable "egress_mode" {
  type = string
}

variable "compute_sg_id" {
  type = string
}

variable "data_sg_id" {
  type = string
}

variable "lambda_ec2_isolation_sg_id" {
  type = string
}

variable "lambda_ec2_rollback_sg_id" {
  type = string
}

variable "interface_endpoints_sg_id" {
  type = string
}

variable "db_port" {
  type = string
}

variable "quarantine_sg_id" {
  type = string
}

variable "ecs_security_policy_services" {
  description = "ECS service security-policy inputs keyed by service name"

  type = map(object({
    task_sg_id      = string
    container_port  = number
    alb_sg_id       = optional(string)
    alb_access      = optional(bool, false)
    database_access = optional(bool, false)
  }))

  default = {}
}

variable "s3_prefix_list_id" {
  description = "AWS-managed S3 prefix list ID used for private S3 access"
  type        = string
  default     = null

  validation {
    condition = (
      length(var.ecs_security_policy_services) == 0 ||
      var.s3_prefix_list_id != null
    )

    error_message = "s3_prefix_list_id must be provided when ECS security-policy services are configured."
  }
}