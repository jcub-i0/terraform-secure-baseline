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

module "compute" {
  source = "./modules/compute"

  vpc_id                         = module.networking.vpc_id
  compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
  instance_profile_name          = module.iam.instance_profile_name
  ebs_kms_key_arn                = module.security.ebs_kms_key_arn
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
}

module "iam" {
  source                   = "./modules/iam"
  cloudtrail_log_group_arn = module.logging.cloudtrail_log_group_arn
  secops_topic_arn         = module.monitoring.secops_topic_arn
  logs_kms_key_arn         = module.security.logs_kms_key_arn
  account_id               = data.aws_caller_identity.current.account_id
  primary_region           = var.primary_region
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
}

module "logging" {
  source                     = "./modules/logging"
  centralized_logs_bucket_id = module.storage.centralized_logs_bucket_id
  logs_kms_key_arn           = module.security.logs_kms_key_arn
  cloudtrail_role_arn        = module.iam.cloudtrail_role_arn
  account_id                 = data.aws_caller_identity.current.account_id
  secops_topic_arn           = module.monitoring.secops_topic_arn
}

module "monitoring" {
  source                    = "./modules/monitoring"
  logs_kms_key_arn          = module.security.logs_kms_key_arn
  cloudtrail_log_group_name = module.logging.cloudtrail_logs_group_name
  secops_emails             = var.secops_emails
}

module "automation" {
  source = "./modules/automation"

  vpc_id                        = module.networking.vpc_id
  lambda_ec2_isolation_role_arn = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn  = module.iam.lambda_ec2_rollback_role_arn
  serverless_private_subnet_ids = module.networking.serverless_subnet_ids_list
  quarantine_sg_id              = module.compute.quarantine_sg_id
  secops_topic_arn              = module.monitoring.secops_topic_arn
  account_id                    = data.aws_caller_identity.current.account_id
  secops_role_arn               = module.iam.secops_role_arn
  primary_region                = var.primary_region
}