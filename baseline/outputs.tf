output "vpc_id" {
  description = "ID of the main VPC"
  value       = module.networking.vpc_id
}

output "name_prefix" {
  description = "Prefix/suffix used in naming convention ({CLOUD_NAME}-{ENV})"
  value       = local.name_prefix
}

output "centralized_logs_bucket_name" {
  description = "Name of the Centralized Logs S3 bucket ('bucket' S3 attribute)"
  value       = module.storage.centralized_logs_bucket_name
}

output "rds_address" {
  description = "DNS address of the RDS instance"
  value       = module.storage.rds_address
}

output "rds_endpoint" {
  description = "Connection endpoint of the RDS instance in address:port form"
  value       = module.storage.rds_endpoint
}

output "rds_port" {
  description = "Port on which the RDS instance accepts connections"
  value       = module.storage.rds_port
}

output "rds_database_name" {
  description = "Initial database name configured on the RDS instance"
  value       = module.storage.rds_database_name
}

output "rds_master_username" {
  description = "Master username configured on the RDS instance"
  value       = module.storage.rds_master_username
}

output "rds_master_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS master password"
  value       = module.storage.rds_master_secret_arn
}

output "data_sg_id" {
  description = "ID of the RDS/data security group"
  value       = module.storage.data_sg_id
}

output "lambda_cmk_arn" {
  description = "ARN of the CMK used to encrypt Lambda functions"
  value       = module.security.lambda_cmk_arn
}

output "secrets_manager_cmk_arn" {
  description = "ARN of the CMK used to encrypt Secrets Manager secrets"
  value       = module.security.secrets_manager_cmk_arn
}

output "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the 'Logs CMK Decrypt Policy' resource"
  value       = module.iam.logs_cmk_decrypt_policy_name
}

output "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the 'Logs S3 Readonly Policy' resource"
  value       = module.iam.logs_s3_readonly_policy_name
}

output "deployment_profile" {
  description = "Selected deployment profile"
  value       = var.deployment_profile
}

output "egress_mode" {
  description = "Selected egress mode input."
  value       = var.egress_mode
}

output "effective_egress_mode" {
  description = "Effective egress mode after resolving deployment_profile and egress_mode"
  value       = local.effective_egress_mode
}

output "effective_allowed_egress_domains" {
  description = "Effective Network Firewall domain targets; empty when Network Firewall is not instantiated"
  value = (
    local.effective_egress_mode == "network_firewall"
    ? module.firewall[0].effective_allowed_egress_domains
    : toset([])
  )
}

output "effective_cloudwatch_retention_days" {
  description = "Effective CloudWatch Logs retention period after resolving deployment_profile and cloudwatch_retention_days override"
  value       = local.effective_cloudwatch_retention_days
}

output "effective_enable_config" {
  description = "Effective AWS Config enablement after resolving deployment_profile and enable_config override."
  value       = local.effective_enable_config
}

output "effective_enable_rules" {
  description = "Effective AWS Config rule group settings after resolving deployment_profile, enable_config, and enable_rules."
  value       = local.effective_enable_rules
}

output "effective_backup_enabled" {
  description = "Effective AWS Backup enablement after resolving deployment_profile."
  value       = local.effective_backup_enabled
}

output "effective_inspector_enabled" {
  description = "Effective Inspector enablement after resolving deployment_profile."
  value       = local.effective_inspector_enabled
}

output "effective_inspector_resource_types" {
  description = "Amazon Inspector resource types enabled after profile and override resolution."
  value       = local.effective_inspector_enabled ? local.effective_inspector_resource_types : []
}

output "db_port" {
  description = "Port used by the database (Postgres=5432, MySQL=3306)"
  value       = var.db_port
}

output "effective_manage_securityhub_cspm_locally" {
  description = "Whether Security Hub CSPM resources are managed locally by Terraform in this workload account"
  value       = var.manage_securityhub_cspm_locally
}

output "effective_manage_securityhub_v2_locally" {
  description = "Whether Security Hub V2 resources are managed locally by Terraform in this workload account"
  value       = var.manage_securityhub_v2_locally
}

output "effective_manage_guardduty_locally" {
  description = "Whether GuardDuty resources are managed locally by Terraform in this workload account"
  value       = var.manage_guardduty_locally
}

output "ecr_repositories" {
  description = "Managed ECR repository metadata keyed by repository name"
  value       = module.ecr.repositories
}

output "application_load_balancer" {
  description = "Shared ECS Application Load Balancer metadata; null when no ALB services are configured"

  value = length(local.ecs_alb_services) > 0 ? {
    arn                = module.application_load_balancer[0].load_balancer_arn
    dns_name           = module.application_load_balancer[0].dns_name
    security_group_id  = module.application_load_balancer[0].security_group_id
    https_listener_arn = module.application_load_balancer[0].https_listener_arn
    target_groups      = module.application_load_balancer[0].target_groups
  } : null
}

output "ecs_cluster" {
  description = "ECS cluster metadata"

  value = {
    arn = module.ecs_cluster.cluster_arn
    name = module.ecs_cluster.cluster_name
  }
}

output "ecs_services" {
  description = "ECS service metadata keyed by service name."
  value       = module.ecs_service.services
}

output "ecs_task_definition_arns" {
  description = "ECS task definition ARNs keyed by service name"
  value = module.ecs_service.task_definition_arns
}

output "ecs_task_security_group_ids" {
  description = "ECS task Security Group IDs keyed by service name"
  value = module.ecs_service.task_security_group_ids
}

output "ecs_log_groups" {
  description = "ECS CloudWatch log-group metadata keyed by service name"
  value = module.ecs_service.log_groups
}