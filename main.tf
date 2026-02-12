# GLOBAL RESOURCES
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
resource "random_id" "random_id" { byte_length = 4 }


# MODULES
module "networking" {
  source = "./modules/networking"

  main_vpc_cidr = var.main_vpc_cidr
  azs           = var.azs
  subnet_cidrs  = var.subnet_cidrs
}

module "rules" {
  source = "./modules/networking/rules"

}

module "compute" {
  source = "./modules/compute"

  vpc_id                         = module.networking.vpc_id
  compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
  instance_profile_name          = module.iam.instance_profile_name
  ebs_kms_key_arn                = module.security.ebs_kms_key_arn
  interface_endpoints_sg_id      = module.vpc_endpoints.interface_endpoints_sg_id
  data_sg_id                     = module.storage.data_sg_id
  db_port                        = var.db_port
}

module "storage" {
  source                       = "./modules/storage"
  vpc_id                       = module.networking.vpc_id
  db_port                      = var.db_port
  compute_sg_id                = module.compute.compute_sg_id
  data_private_subnet_ids_list = module.networking.data_private_subnet_ids_list
  db_username                  = var.db_username
  db_password                  = var.db_password
  logs_kms_key_arn             = module.security.logs_kms_key_arn
  account_id                   = data.aws_caller_identity.current.account_id
  random_id                    = random_id.random_id.hex
  cloudtrail_arn               = module.logging.cloudtrail_arn
  bucket_admin_principles      = var.bucket_admin_principles
}

module "iam" {
  source                                = "./modules/iam"
  cloudtrail_log_group_arn              = module.logging.cloudtrail_log_group_arn
  secops_topic_arn                      = module.monitoring.secops_topic_arn
  logs_kms_key_arn                      = module.security.logs_kms_key_arn
  account_id                            = data.aws_caller_identity.current.account_id
  primary_region                        = var.primary_region
  centralized_logs_bucket_arn           = module.storage.centralized_logs_bucket_arn
  flowlogs_firehose_delivery_stream_arn = module.logging.flowlogs_firehose_delivery_stream_arn
  flowlogs_log_group_arn                = module.logging.flowlogs_log_group_arn
  secops_event_bus_arn                  = module.automation.secops_event_bus_arn
}

module "security" {
  source = "./modules/security"

  config_role_arn              = module.iam.config_role_arn
  centralized_logs_bucket_name = module.storage.centralized_logs_bucket_name
  current_region               = data.aws_region.current.region
  account_id                   = data.aws_caller_identity.current.account_id
  compliance_topic_arn         = module.monitoring.compliance_topic_arn
  primary_region               = var.primary_region
  guardduty_features           = var.guardduty_features
  config_remediation_role_arn  = module.iam.config_remediation_role_arn
  secops_event_bus_name        = module.automation.secops_event_bus_name
  secops_topic_arn             = module.monitoring.secops_topic_arn
}

module "logging" {
  source                      = "./modules/logging"
  centralized_logs_bucket_id  = module.storage.centralized_logs_bucket_id
  logs_kms_key_arn            = module.security.logs_kms_key_arn
  cloudtrail_role_arn         = module.iam.cloudtrail_role_arn
  account_id                  = data.aws_caller_identity.current.account_id
  secops_topic_arn            = module.monitoring.secops_topic_arn
  flowlogs_role_arn           = module.iam.flowlogs_role_arn
  vpc_id                      = module.networking.vpc_id
  firehose_flow_logs_role_arn = module.iam.firehose_flow_logs_role_arn
  centralized_logs_bucket_arn = module.storage.centralized_logs_bucket_arn
  cw_to_firehose_role_arn     = module.iam.cw_to_firehose_role_arn
}

module "monitoring" {
  source                    = "./modules/monitoring"
  logs_kms_key_arn          = module.security.logs_kms_key_arn
  cloudtrail_log_group_name = module.logging.cloudtrail_logs_group_name
  secops_emails             = var.secops_emails
}

module "automation" {
  source = "./modules/automation"

  vpc_id                                   = module.networking.vpc_id
  lambda_ec2_isolation_role_arn            = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn             = module.iam.lambda_ec2_rollback_role_arn
  serverless_private_subnet_ids            = module.networking.serverless_private_subnet_ids_list
  quarantine_sg_id                         = module.compute.quarantine_sg_id
  secops_topic_arn                         = module.monitoring.secops_topic_arn
  account_id                               = data.aws_caller_identity.current.account_id
  secops_role_arn                          = module.iam.secops_role_arn
  primary_region                           = var.primary_region
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn
  lambda_kms_key_arn                       = module.security.lambda_kms_key_arn
  interface_endpoints_sg_id                = module.vpc_endpoints.interface_endpoints_sg_id
}

module "vpc_endpoints" {
  source = "./modules/vpc_endpoints"

  vpc_id                            = module.networking.vpc_id
  account_id                        = data.aws_caller_identity.current.account_id
  primary_region                    = var.primary_region
  compute_private_subnet_ids_map    = module.networking.compute_private_subnet_ids_map
  serverless_private_subnet_ids_map = module.networking.serverless_private_subnet_ids_map
  subnet_cidrs                      = var.subnet_cidrs
  compute_sg_id                     = module.compute.compute_sg_id
  lambda_ec2_isolation_sg_id        = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id         = module.automation.lambda_ec2_rollback_sg_id
}