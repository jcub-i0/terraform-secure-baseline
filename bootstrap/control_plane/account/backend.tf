terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-control-plane-state"
    key            = "control-plane/account.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true
  }
}