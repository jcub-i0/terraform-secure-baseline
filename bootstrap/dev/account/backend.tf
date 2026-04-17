terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-dev-state"
    key            = "tf-state-bootstrap-dev"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-dev-lock"
  }
}