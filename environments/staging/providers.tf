terraform {
  required_version = ">=1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=6.40.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }
}

provider "aws" {
  region = var.primary_region
}