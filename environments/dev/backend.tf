terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-dev-state"
    key            = "tf-state-baseline-dev"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-dev-lock"
    use_lockfile   = true
  }
}