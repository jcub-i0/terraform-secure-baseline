module "networking" {
  source = "./modules/networking"

  main_vpc_cidr                   = var.main_vpc_cidr
  public_subnet_cidrs             = var.public_subnet_cidrs
  compute_private_subnet_cidrs    = var.compute_private_subnet_cidrs
  data_private_subnet_cidrs       = var.data_private_subnet_cidrs
  serverless_private_subnet_cidrs = var.serverless_private_subnet_cidrs
}

module "compute" {
  source = "./modules/compute"

  vpc_id = module.networking.vpc_id
}