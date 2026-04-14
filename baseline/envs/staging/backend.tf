terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-state"
    key            = "tf-state-baseline-staging"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-tf-lock"
  }
}