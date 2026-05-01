terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-staging-state"
    key            = "baseline/staging.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true
  }
}