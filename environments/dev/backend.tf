terraform {
  backend "s3" {
    bucket       = "tf-secure-baseline-dev-state"
    key          = "baseline/dev.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}