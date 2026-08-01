terraform {
  backend "s3" {
    bucket       = "tf-secure-baseline-security-operations-state"
    key          = "security-operations/account.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}