terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-state"
    key            = "tf-state-account-services"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-lock"
  }
}