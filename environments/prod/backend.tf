terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-prod-state"
    key            = "tf-state-baseline-prod"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-prod-lock"
    use_lockfile   = true
  }
}