variable "vpc_id" {
  type = string
}

variable "lambda_ec2_isolation_role_arn" {
  type = string
}

variable "lambda_ec2_rollback_role_arn" {
  type = string
}

variable "lambda_ip_enrichment_role_arn" {
  type = string
}

variable "serverless_private_subnet_ids" {
  type = list(string)
}

variable "quarantine_sg_id" {
  type = string
}

variable "secops_topic_arn" {
  type = string
}

variable "account_id" {
  type = string
}

variable "secops_operator_role_arn" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "eventbridge_putevents_to_secops_role_arn" {
  type = string
}

variable "lambda_kms_key_arn" {
  type = string
}

variable "secrets_manager_cmk_arn" {
  type = string
}

variable "interface_endpoints_sg_id" {
  type = string
}

variable "logs_kms_key_arn" {
  type = string
}

variable "ip_enrichment_write_to_securityhub" {
  type = bool
}

variable "abuseipdb_api_key" {
  type      = string
  sensitive = true
}

variable "ip_enrich_max_ips_per_event" {
  type = string
}

variable "ip_enrich_abuseipdb_max_age" {
  type = string
}

variable "ip_enrich_max_ips_extracted" {
  type = string
}