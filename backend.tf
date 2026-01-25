terraform {
  backend "s3" {
    bucket = "baseline-tf-state"
    key = "baseline-tf-state/tf-state"
    region = "us-east-1"
    encrypt = true
  }
}