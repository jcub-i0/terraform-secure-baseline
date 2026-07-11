terraform {
  backend "s3" {
    bucket       = "tf-secure-baseline-prod-state"
    key          = "bootstrap/account/prod.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}