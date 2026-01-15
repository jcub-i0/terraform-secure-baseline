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
}

module "iam" {
  source                   = "./modules/iam"
  cloudtrail_log_group_arn = module.logging.cloudtrail_log_group_arn
}

module "security" {
  source = "./modules/security"
}

module "logging" {
  source                     = "./modules/logging"
  centralized_logs_bucket_id = module.storage.centralized_logs_bucket_id
  logs_kms_key_arn           = module.security.logs_kms_key_arn
  cloudtrail_role_arn        = module.iam.cloudtrail_role_arn
}