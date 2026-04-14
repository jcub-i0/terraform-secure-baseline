terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-state"
    key            = "tf-state-baseline-dev"
    region         = "us-east-1"
    encrypt        = true
  }
}