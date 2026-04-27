terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-control-plane-state"
    key            = "control-plane/identity-center.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-control-plane-lock"
    use_lockfile   = true
  }
}