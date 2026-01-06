module "networking" {
  source                   = "./modules/networking"
  
  main_vpc_cidr            = var.main_vpc_cidr
  data_private_subnet_cidrs = var.data_private_subnet_cidrs
}