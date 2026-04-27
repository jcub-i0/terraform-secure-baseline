terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-bootstrap-state"
    key            = "control-plane/account.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-bootstrap-lock"
    use_lockfile   = true
  }
}