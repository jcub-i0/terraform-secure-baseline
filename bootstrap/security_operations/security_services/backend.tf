terraform {
  backend "s3" {
    bucket       = "tf-secure-baseline-security-operations-state"
    key          = "security-operation/security-services.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}