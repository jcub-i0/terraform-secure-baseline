module "networking" {
  source = "./modules/networking"

  main_vpc_cidr                   = var.main_vpc_cidr
  azs = var.azs
  subnet_cidrs = var.subnet_cidrs
}

module "compute" {
  source = "./modules/compute"

  vpc_id = module.networking.vpc_id
  compute_private_subnet_ids = module.networking.compute_private_subnet_ids
  ec2_ami_name = var.ec2_ami_name
}