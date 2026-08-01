terraform {
  required_version = ">=1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=6.44.0"
    }
  }
}

provider "aws" {
  region = var.primary_region
}