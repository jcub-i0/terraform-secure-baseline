terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-staging-state"
    key            = "tf-state-bootstrap-staging"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-staging-lock"
    use_lockfile = true
  }
}