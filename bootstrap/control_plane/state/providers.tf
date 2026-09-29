terraform {
  required_version = "=1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.66.0"
    }
  }
}

provider "aws" {
  region = var.primary_region
}