terraform {
  backend "s3" {
    bucket  = "baseline-tf-state"
    key     = "baseline-tf-state/tf-state-bootstrap"
    region  = "us-east-1"
    encrypt = true
  }
}