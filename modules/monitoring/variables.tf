variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "cloudtrail_logs_group_name" {
  type = string
}

variable "secops_emails" {
  type = list(string)
}

variable "tamper_detection_rule_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "lambda_ip_enrichment_role_arn" {
  type = string
}

variable "lambda_ec2_isolation_role_arn" {
  type = string
}

variable "lambda_ec2_rollback_role_arn" {
  type = string
}

variable "break_glass_admin_role_arn" {
  type = string
}

variable "securityhub_high_critical_rule_name" {
  type = string
}

variable "securityhub_high_critical_rule_arn" {
  type = string
}

variable "ecs_task_deficit_services" {
  description = "ECS services monitored for desired-versus-running task deficits."

  type = map(object({
    cluster_name = string
    service_name = string
  }))

  default = {}
}

variable "ecs_ingress_services" {
  description = "Ingress-enabled ECS services monitored for unhealthy ALB targets."

  type = map(object({
    load_balancer_arn_suffix = string
    target_group_arn_suffix  = string
  }))

  default = {}
}