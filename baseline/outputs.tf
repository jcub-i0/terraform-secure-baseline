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

output "rds_configuration" {
  description = "Validator-relevant Terraform-managed RDS configuration."
  value       = module.storage.rds_configuration
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

output "logs_cmk_arn" {
  description = "ARN of the CMK used to encrypt workload CloudWatch Logs"
  value       = module.security.logs_cmk_arn
}

output "logs_cmk_decrypt_policy_name" {
  description = "'Name' attribute of the 'Logs CMK Decrypt Policy' resource"
  value       = module.iam.logs_cmk_decrypt_policy_name
}

output "logs_s3_readonly_policy_name" {
  description = "'Name' attribute of the 'Logs S3 Readonly Policy' resource"
  value       = module.iam.logs_s3_readonly_policy_name
}

output "network_topology" {
  description = "Terraform-managed workload network topology keyed by subnet class and Availability Zone"

  value = {
    availability_zones = sort(
      keys(module.networking.compute_private_subnet_ids_map)
    )

    public_subnet_ids_by_az = (
      module.networking.public_subnet_ids_map
    )

    compute_private_subnet_ids_by_az = (
      module.networking.compute_private_subnet_ids_map
    )

    data_private_subnet_ids_by_az = (
      module.networking.data_private_subnet_ids_map
    )

    serverless_private_subnet_ids_by_az = (
      module.networking.serverless_private_subnet_ids_map
    )

    endpoint_private_subnet_ids_by_az = (
      module.networking.endpoint_private_subnet_ids_map
    )

    firewall_private_subnet_ids_by_az = (
      module.networking.firewall_private_subnet_ids_map
    )

    nat_gateway_ids_by_az = (
      module.networking.nat_gateway_ids_map
    )

    firewall_endpoint_ids_by_az = (
      local.effective_egress_mode == "network_firewall"
      ? module.firewall[0].firewall_endpoint_ids_by_az
      : {}
    )
  }
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

output "effective_backup_schedule" {
  description = "Effective AWS Backup schedule after resolving deployment_profile and backup_schedule override; null when backups are disabled"
  value       = local.effective_backup_schedule
}

output "effective_delete_backups_after_days" {
  description = "Effective AWS Backup retention period in days after resolving deployment_profile and delete_backups_after_days override; null when backups are disabled"
  value       = local.effective_delete_backups_after_days
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

output "secops_topic_arn" {
  description = "ARN of the SecOps SNS notification topic."
  value       = module.monitoring.secops_topic_arn
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

output "lifecycle_protection" {
  description = "Effective destructive-lifecycle posture used by validation."

  value = {
    production_retirement_mode         = local.effective_production_retirement_mode
    rds_deletion_protection            = local.effective_rds_deletion_protection
    alb_deletion_protection            = local.effective_alb_deletion_protection
    network_firewall_delete_protection = local.effective_network_firewall_delete_protection
    ecr_force_delete                   = local.effective_ecr_force_delete
    ecs_service_force_delete           = local.effective_ecs_service_force_delete
    backup_vault_force_destroy         = local.effective_backup_vault_force_destroy
  }
}

output "ecr_repositories" {
  description = "Managed ECR repository metadata keyed by repository name"
  value       = module.ecr.repositories
}

output "ecr_cmk_arn" {
  description = "ARN of the KMS CMK used to encrypt workload ECR repositories"
  value       = module.security.ecr_cmk_arn
}

output "application_load_balancer" {
  description = "Shared ECS Application Load Balancer metadata; null when no ALB services are configured"

  value = length(local.ecs_alb_services) > 0 ? {
    arn               = module.application_load_balancer[0].load_balancer_arn
    arn_suffix        = module.application_load_balancer[0].load_balancer_arn_suffix
    dns_name          = module.application_load_balancer[0].dns_name
    security_group_id = module.application_load_balancer[0].security_group_id
    https_listener    = module.application_load_balancer[0].https_listener
    target_groups     = module.application_load_balancer[0].target_groups
  } : null
}

output "ecs_cluster" {
  description = "ECS cluster metadata"

  value = {
    arn                          = module.ecs_cluster.cluster_arn
    name                         = module.ecs_cluster.cluster_name
    container_insights           = module.ecs_cluster.container_insights
    container_insights_log_group = module.ecs_cluster.container_insights_log_group

    guardduty_fargate_runtime_monitoring_enabled = (
      module.ecs_cluster.guardduty_fargate_runtime_monitoring_enabled
    )

    guardduty_managed_tag_value = (
      module.ecs_cluster.guardduty_managed_tag_value
    )
  }
}

output "ecs_services" {
  description = "ECS service metadata keyed by service name"
  value       = module.ecs_service.services
}

output "ecs_service_configuration" {
  description = "Validator-relevant ECS service configuration keyed by service name"

  value = {
    for service_name, service in local.deployable_ecs_services :
    service_name => {
      desired_count = service.desired_count
      scaling       = service.scaling
      deployment    = service.deployment

      ingress_enabled = service.ingress != null

      database_access             = service.database_access
      task_execution_kms_key_arns = sort(tolist(service.task_execution_kms_key_arns))

      guardduty_agent_ecr_repository_arns = sort(
        tolist(
          local.ecs_iam_services[service_name].guardduty_agent_ecr_repository_arns
        )
      )
    }
  }
}

output "ecs_autoscaling_targets" {
  description = "Application Auto Scaling targets keyed by ECS service name."
  value       = module.ecs_service.autoscaling_targets
}

output "ecs_autoscaling_cpu_policies" {
  description = "CPU target-tracking policies keyed by ECS service name."
  value       = module.ecs_service.autoscaling_cpu_policies
}

output "ecs_autoscaling_memory_policies" {
  description = "Memory target-tracking policies keyed by ECS service name."
  value       = module.ecs_service.autoscaling_memory_policies
}

output "ecs_autoscaling_alb_request_policies" {
  description = "ALB request-count target-tracking policies keyed by ECS service name"
  value       = module.ecs_service.autoscaling_alb_request_policies
}

output "ecs_task_definition_arns" {
  description = "ECS task definition ARNs keyed by service name"
  value       = module.ecs_service.task_definition_arns
}

output "ecs_task_security_group_ids" {
  description = "ECS task Security Group IDs keyed by service name"
  value       = module.ecs_service.task_security_group_ids
}

output "ecs_log_groups" {
  description = "ECS CloudWatch log-group metadata keyed by service name"
  value       = module.ecs_service.log_groups
}

output "ecs_task_execution_roles" {
  description = "ECS task execution roles keyed by service name"
  value       = module.iam.ecs_task_execution_roles
}

output "ecs_task_roles" {
  description = "ECS application task roles keyed by service name"
  value       = module.iam.ecs_task_roles
}

output "ecs_task_deficit_alarms" {
  description = "ECS task-deficit operational alarms keyed by service name."
  value       = module.monitoring.ecs_task_deficit_alarms
}

output "ecs_ingress_unhealthy_target_alarms" {
  description = "ECS ingress unhealthy-target operational alarms keyed by service name."
  value       = module.monitoring.ecs_ingress_unhealthy_target_alarms
}

output "guardduty_ecs_runtime_coverage_notification" {
  description = "GuardDuty ECS Runtime Monitoring coverage-status notification metadata"
  value       = module.monitoring.guardduty_ecs_runtime_coverage_notification
}

output "interface_endpoint_ids" {
  description = "Interface VPC Endpoint IDs keyed by AWS service short name"
  value       = module.vpc_endpoints.interface_endpoint_ids
}

output "s3_prefix_list_id" {
  description = "AWS-managed S3 prefix list ID associated with the workload S3 Gateway Endpoint."
  value       = module.vpc_endpoints.s3_prefix_list_id
}

output "restore_testing" {
  description = "Effective and resource-backed AWS Backup Restore Testing configuration used by validation."

  value = {
    enabled = local.effective_restore_testing_enabled

    schedule = (
      local.effective_restore_testing_schedule
    )

    start_window_hours = (
      local.effective_restore_testing_start_window_hours
    )

    selection_window_days = (
      local.effective_restore_testing_selection_window_days
    )

    validation_window_hours = (
      local.effective_restore_testing_validation_window_hours
    )

    plan = module.backup.restore_testing_plan

    selection = module.backup.restore_testing_selection
  }
}