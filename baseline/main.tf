# ====================================================================
# NOTICE: PROPRIETARY CODE
# ====================================================================
# This repository is the property of Nano Nexus Consulting.
#
#
# This code is made publicly viewable for demonstration purposes only.
# No license is granted to use, copy, modify, or distribute this code
# without explicit written permission.                                  
# ==================================================================== 

###############
# MODULE CALLS
###############

module "networking" {
  source = "../modules/networking"

  name_prefix = local.name_prefix
  environment = var.environment
  cloud_name  = var.cloud_name

  main_vpc_cidr = var.main_vpc_cidr
  subnet_cidrs  = var.subnet_cidrs
  azs           = var.azs

  egress_mode = local.effective_egress_mode

  firewall_endpoint_ids_by_az = (
    local.effective_egress_mode == "network_firewall"
    ? module.firewall[0].firewall_endpoint_ids_by_az
    : {}
  )
}

module "security_policy" {
  source = "../modules/networking/security_policy"

  egress_mode                = local.effective_egress_mode
  compute_sg_id              = module.compute.compute_sg_id
  data_sg_id                 = module.storage.data_sg_id
  lambda_ec2_isolation_sg_id = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id  = module.automation.lambda_ec2_rollback_sg_id
  interface_endpoints_sg_id  = module.vpc_endpoints.interface_endpoints_sg_id
  db_port                    = var.db_port
}

module "compute" {
  source = "../modules/compute"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  environment = var.environment

  compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
  instance_profile_name          = module.iam.instance_profile_name
  ebs_cmk_arn                    = module.security.ebs_cmk_arn

  interface_endpoints_sg_id = module.vpc_endpoints.interface_endpoints_sg_id
  data_sg_id                = module.storage.data_sg_id
  db_port                   = var.db_port
  patch_tag_value           = var.patch_tag_value
}

module "storage" {
  source = "../modules/storage"

  name_prefix = local.name_prefix
  environment = var.environment
  vpc_id      = module.networking.vpc_id
  account_id  = var.account_id
  random_id   = var.random_id

  db_port     = var.db_port
  db_username = var.db_username

  compute_sg_id                = module.compute.compute_sg_id
  data_private_subnet_ids_list = module.networking.data_private_subnet_ids_list

  cloudwatch_retention_days = local.effective_cloudwatch_retention_days

  logs_cmk_arn            = module.security.logs_cmk_arn
  secrets_manager_cmk_arn = module.security.secrets_manager_cmk_arn
  cloudtrail_arn          = module.logging.cloudtrail_arn
  bucket_admin_principals = var.bucket_admin_principals
}

module "iam" {
  source = "../modules/iam"

  cloud_name     = var.cloud_name
  name_prefix    = local.name_prefix
  environment    = var.environment
  account_id     = var.account_id
  primary_region = var.primary_region

  cloudtrail_log_group_arn = module.logging.cloudtrail_log_group_arn
  secops_topic_arn         = module.monitoring.secops_topic_arn
  logs_cmk_arn             = module.security.logs_cmk_arn
  secrets_manager_cmk_arn  = module.security.secrets_manager_cmk_arn

  centralized_logs_bucket_arn           = module.storage.centralized_logs_bucket_arn
  flowlogs_firehose_delivery_stream_arn = module.logging.flowlogs_firehose_delivery_stream_arn
  flowlogs_log_group_arn                = module.logging.flowlogs_log_group_arn
  secops_event_bus_arn                  = module.automation.secops_event_bus_arn

  threat_intel_api_keys_arn          = module.automation.threat_intel_api_keys_arn
  lambda_ip_enrichment_log_group_arn = module.automation.lambda_ip_enrichment_log_group_arn
  break_glass_trusted_principal_arns = var.break_glass_trusted_principal_arns

  lambda_ec2_isolation_dlq_arn = module.automation.lambda_ec2_isolation_dlq_arn
  lambda_ec2_rollback_dlq_arn  = module.automation.lambda_ec2_rollback_dlq_arn
  lambda_ip_enrichment_dlq_arn = module.automation.lambda_ip_enrichment_dlq_arn
}

module "security" {
  source = "../modules/security"

  name_prefix                  = local.name_prefix
  cloud_name                   = var.cloud_name
  environment                  = var.environment
  account_id                   = var.account_id
  primary_region               = var.primary_region
  centralized_logs_bucket_name = module.storage.centralized_logs_bucket_name

  guardduty_features       = var.guardduty_features
  enable_rules             = local.effective_enable_rules
  inspector_enabled        = local.effective_inspector_enabled
  inspector_resource_types = var.inspector_resource_types

  enable_config               = local.effective_enable_config
  config_role_arn             = module.iam.config_role_arn
  config_remediation_role_arn = module.iam.config_remediation_role_arn

  compliance_topic_arn  = module.monitoring.compliance_topic_arn
  secops_topic_arn      = module.monitoring.secops_topic_arn
  secops_event_bus_name = module.automation.secops_event_bus_name
}

module "logging" {
  source = "../modules/logging"

  cloud_name  = var.cloud_name
  environment = var.environment
  name_prefix = local.name_prefix

  vpc_id     = module.networking.vpc_id
  account_id = var.account_id

  centralized_logs_bucket_id  = module.storage.centralized_logs_bucket_id
  centralized_logs_bucket_arn = module.storage.centralized_logs_bucket_arn
  logs_cmk_arn                = module.security.logs_cmk_arn

  cloudwatch_retention_days = local.effective_cloudwatch_retention_days

  cloudtrail_role_arn         = module.iam.cloudtrail_role_arn
  flowlogs_role_arn           = module.iam.flowlogs_role_arn
  firehose_flow_logs_role_arn = module.iam.firehose_flow_logs_role_arn
  cw_to_firehose_role_arn     = module.iam.cw_to_firehose_role_arn
}

module "monitoring" {
  source = "../modules/monitoring"

  name_prefix = local.name_prefix
  environment = var.environment
  account_id  = var.account_id

  cloudtrail_logs_group_name          = module.logging.cloudtrail_logs_group_name
  logs_cmk_arn                        = module.security.logs_cmk_arn
  tamper_detection_rule_arn           = module.security.tamper_detection_rule_arn
  securityhub_high_critical_rule_arn  = module.automation.securityhub_high_critical_rule_arn
  securityhub_high_critical_rule_name = module.automation.securityhub_high_critical_rule_name

  lambda_ip_enrichment_role_arn = module.iam.lambda_ip_enrichment_role_arn
  lambda_ec2_isolation_role_arn = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn  = module.iam.lambda_ec2_rollback_role_arn
  break_glass_admin_role_arn    = module.iam.break_glass_admin_role_arn

  secops_emails = var.secops_emails
}

module "automation" {
  source = "../modules/automation"

  cloud_name     = var.cloud_name
  account_id     = var.account_id
  name_prefix    = local.name_prefix
  environment    = var.environment
  primary_region = var.primary_region

  vpc_id                        = module.networking.vpc_id
  serverless_private_subnet_ids = module.networking.serverless_private_subnet_ids_list
  interface_endpoints_sg_id     = module.vpc_endpoints.interface_endpoints_sg_id
  quarantine_sg_id              = module.compute.quarantine_sg_id

  lambda_ec2_isolation_role_arn            = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn             = module.iam.lambda_ec2_rollback_role_arn
  lambda_ip_enrichment_role_arn            = module.iam.lambda_ip_enrichment_role_arn
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn

  cloudwatch_retention_days = local.effective_cloudwatch_retention_days

  secops_topic_arn        = module.monitoring.secops_topic_arn
  lambda_cmk_arn          = module.security.lambda_cmk_arn
  logs_cmk_arn            = module.security.logs_cmk_arn
  secrets_manager_cmk_arn = module.security.secrets_manager_cmk_arn

  abuseipdb_api_key = var.abuseipdb_api_key

  ip_enrichment_write_to_securityhub = var.ip_enrichment_write_to_securityhub
  ip_enrich_max_ips_per_event        = var.ip_enrich_max_ips_per_event
  ip_enrich_abuseipdb_max_age        = var.ip_enrich_abuseipdb_max_age
  ip_enrich_max_ips_extracted        = var.ip_enrich_max_ips_extracted
}

module "vpc_endpoints" {
  source = "../modules/vpc_endpoints"

  name_prefix    = local.name_prefix
  vpc_id         = module.networking.vpc_id
  environment    = var.environment
  account_id     = var.account_id
  primary_region = var.primary_region

  compute_private_subnet_ids_map       = module.networking.compute_private_subnet_ids_map
  serverless_private_subnet_ids_map    = module.networking.serverless_private_subnet_ids_map
  endpoint_private_subnet_ids_map      = module.networking.endpoint_private_subnet_ids_map
  endpoint_private_route_table_ids_map = module.networking.endpoint_private_route_table_ids_map

  s3_gateway_endpoint_rt_ids_list = concat(
    values(module.networking.endpoint_private_route_table_ids_map),
    values(module.networking.compute_private_route_table_ids_map),
    values(module.networking.serverless_private_route_table_ids_map)
  )

  subnet_cidrs  = var.subnet_cidrs
  compute_sg_id = module.compute.compute_sg_id

  lambda_ec2_isolation_sg_id = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id  = module.automation.lambda_ec2_rollback_sg_id
}

module "firewall" {
  count  = local.effective_egress_mode == "network_firewall" ? 1 : 0
  source = "../modules/firewall"

  name_prefix = local.name_prefix
  cloud_name  = var.cloud_name
  environment = var.environment
  vpc_id      = module.networking.vpc_id

  cloudwatch_retention_days = local.effective_cloudwatch_retention_days

  firewall_private_subnet_ids_map = module.networking.firewall_private_subnet_ids_map
  logs_cmk_arn                    = module.security.logs_cmk_arn
  centralized_logs_bucket_arn     = module.storage.centralized_logs_bucket_arn
  centralized_logs_bucket_name    = module.storage.centralized_logs_bucket_name
}

module "patch_management" {
  source = "../modules/patch_management"

  name_prefix                       = local.name_prefix
  environment                       = var.environment
  patch_maintenance_window_role_arn = module.iam.patch_maintenance_window_role_arn
  patch_tag_value                   = var.patch_tag_value
}

module "security_dashboard" {
  source = "../modules/security_dashboard"

  environment = var.environment

  depends_on = [
    module.security
  ]
}

module "backup" {
  source = "../modules/backup"

  name_prefix = local.name_prefix
  environment = var.environment

  backup_enabled            = local.effective_backup_enabled
  backup_schedule           = var.backup_schedule
  backup_vault_cmk_arn      = module.security.backup_vault_cmk_arn
  delete_backups_after_days = var.delete_backups_after_days
  backup_service_role_arn   = module.iam.backup_service_role_arn
}