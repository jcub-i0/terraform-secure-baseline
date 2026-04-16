provider "aws" {
  region = var.primary_region

  assume_role {
    role_arn = var.deployment_role_arn
  }
}