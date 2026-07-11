terraform {
  backend "s3" {
    bucket       = "tf-secure-baseline-staging-state"
    key          = "bootstrap/account/staging.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}