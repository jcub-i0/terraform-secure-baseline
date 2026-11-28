output "backend" {
  description = "Non-secret S3 backend settings for the application root; use the default Terraform workspace."
  value = {
    bucket       = aws_s3_bucket.state.bucket
    key          = local.state_key
    region       = data.aws_region.current.region
    encrypt      = true
    kms_key_id   = aws_kms_key.state.arn
    use_lockfile = true
  }
}

output "iam_resources" {
  description = "Exact resources for the separate protected application deployment IAM policies."
  value = {
    bucket_arn       = local.bucket_arn
    state_object_arn = local.state_object_arn
    lock_object_arn  = local.lock_object_arn
    cmk_arn          = aws_kms_key.state.arn
  }
}
