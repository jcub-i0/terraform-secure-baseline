terraform {
  backend "s3" {
    bucket  = "tf-secure-baseline-state"
    key     = "tf-state-baseline-prod"
    region  = "us-east-1"
    encrypt = true
  }
}