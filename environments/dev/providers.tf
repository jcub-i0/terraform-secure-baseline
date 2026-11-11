terraform {
  required_version = "=1.17.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.72.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.2"
    }
  }
}

provider "aws" {
  region = var.primary_region
}